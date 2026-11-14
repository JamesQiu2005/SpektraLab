//  SubjectFinder.swift — 主体, 背景 and 人: the subject and the people of a photograph, found on this Mac (PRD-E §5.3,
//  RFC-052 §5, §8.3, §9; M1c).
//
//  **What is asked** (RFC-052 §9), each of Apple's Vision on this Mac, no model file, nothing downloaded or uploaded:
//
//  | mask | request | what comes back here (measured, `tools/subject_find.sh`) |
//  |---|---|---|
//  | 主体 (背景 by the part's invert) | `GenerateForegroundInstanceMaskRequest`, all instances, `generateScaledMask(for:scaledToImageFrom:)` | a float mask at the rendition's size, from a 512 × 512 model mask |
//  | 人 n | `GeneratePersonInstanceMaskRequest`, one instance at a time, scaled the same way | one mask a person, at the rendition's size |
//  | 全部人物 | `VNGeneratePersonSegmentationRequest` (the Objective-C one: `VisionDetector.people` says why), `.accurate`, 8-bit output | the model's size, whatever the input's: stretched over S |
//
//  Each request's revision is **pinned** (`.revision1`, the only one this system lists, and recorded in the asset's
//  provenance), never "the latest": a later system's revision 2 is a new detector, asked for by name in a later
//  build, never taken silently. All three Swift requests are declared for Mac Catalyst 18 in this SDK (Xcode 27.2's
//  `arm64e-apple-ios-macabi.swiftinterface`: `@available(… iOS 18.0 …)`), the app's floor; the segmentation is asked
//  through its `VN…` form all the same, for its pixels (`VisionDetector.people`).
//
//  **What it is found on**: a display-referred rendition of the *source* in S (RFC-052 §5) — the uncut decode after
//  EXIF orientation and, where the edit has it on, the decoder's lens correction: for a RAW the page's kept decode
//  (`RawProxy`) where it is large enough, else the RAW decoded by the app's own recipe (`RawExposure.prepare`, the
//  edit's decode settings); for any other file ImageIO's picture with its orientation applied. Never the developed
//  picture (the film, the paper and black and white must not change what a subject is), never a cut. Rendered once to
//  8-bit sRGB (the linear decode with sRGB's curve, clipped) at `renditionLongEdge`: see its note for the measurement.
//
//  **What it returns**: an 8-bit picture in S at the size the detector returned, capped at L_c (4096), and its
//  provenance (`FoundMask`: kind, instance, detector, revision, system build, the rendition's fingerprint, the decode
//  geometry). A result is tagged with the frame and the decode geometry it was made from (`FindTag`); a result that
//  lands after the page moved to another frame, or after the decode's geometry changed, is dropped (`focus`,
//  `Failure.dropped`). The page keeps one memo, the focused frame's (`people` a second time answers at once).
//
//  **When a request is not there** (an Intel Mac whose GPU the model does not run on, RFC-052 §9's gate 11, unverified
//  here): `Failure.unavailable`, which the interface says as "not available on this Mac"; the brush and the gradients
//  need no detector. `UnavailableDetector` forces that path for a check.
//
//  An actor of its own, off the main actor: a find is a decode and a model's run, 0.1–0.5 s warm, 1–3 s the first time
//  a launch asks (the model's load).

import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Vision

/// What a find is made from: the frame, its original and the decode the edit asks of it.
struct FindSource: Sendable, Equatable {
    var frame: UUID
    var url: URL
    var isRAW: Bool
    var decode: DecodeSettings
    /// A RAW's kept uncut decode (`RawProxy`), read where it is at least the rendition's size.
    var proxy: URL? = nil

    /// The decode's geometry as a word: what moves the picture in S. Today a RAW's lens correction, and whose it is
    /// with which distortion where the app corrects it (`LensCorrection.geometryWord`: "" otherwise, so other frames'
    /// words are what they were; the light falloff moves no pixel's place); orientation is the file's own and always
    /// applied.
    var geometry: String { isRAW ? "raw|lens=\(decode.lensCorrection ? 1 : 0)" + lensWord : "image" }
    var lensWord: String { LensCorrection.geometryWord(source: url, decode: decode, isRAW: isRAW) }
    var tag: FindTag { FindTag(frame: frame, geometry: geometry) }
    /// The layer's `madeOn` for a mask found on this source (RFC-052 §8.1).
    var madeOn: MaskMadeOn { MaskMadeOn(lensCorrection: isRAW && decode.lensCorrection, lensWord: lensWord) }
}

/// Which frame and which decode a result is of.
struct FindTag: Hashable, Sendable {
    var frame: UUID
    var geometry: String
}

/// A rectangle in S, normalised (origin top-left).
struct MaskRect: Equatable, Sendable, Codable {
    var x: Double, y: Double, width: Double, height: Double
}

/// One found mask, not yet kept: its picture and provenance, and the box of its covered part.
struct FoundResult: Sendable {
    var tag: FindTag
    /// The provenance (`invert` false: 背景 is the part's).
    var mask: FoundMask
    var picture: FoundPicture
    /// The box of what is covered (≥ ½), in S; nil where nothing is.
    var box: MaskRect?
}

/// 人's menu (MASKS-SPEC §6.4): 全部人物 and each person, with the square the menu shows of them.
struct PeopleResult: Sendable {
    struct Person: Sendable {
        /// 1-based, the menu's 人物 n.
        var number: Int
        var found: FoundResult
        /// A square of the photograph (in its pixels) round the person, in S: the menu's 28 × 28.
        var thumbnail: MaskRect
    }
    var tag: FindTag
    /// 全部人物 (`GeneratePersonSegmentationRequest`); nil where nobody is found.
    var all: FoundResult?
    var people: [Person]
    /// The count 全部人物 shows: the people the instance request found.
    var count: Int { people.count }
}

/// What finds the masks: Vision, or a check's stand-in.
protocol MaskDetector: Sendable {
    /// Every instance of the foreground as one mask; nil where nothing is found.
    func subject(_ image: CGImage) async throws -> FoundPicture?
    /// One mask a person.
    func persons(_ image: CGImage) async throws -> [FoundPicture]
    /// All people as one matte, at the model's size; nil where nobody is.
    func people(_ image: CGImage) async throws -> FoundPicture?
}

actor SubjectFinder {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The request does not run on this Mac (its model, its GPU): the button says "not available on this Mac".
        case unavailable(String)
        /// The source could not be read or decoded.
        case noSource(String)
        /// The request ran and failed.
        case failed(String)
        /// The page moved to another frame, or the decode's geometry changed, while it was looked for.
        case dropped
        var description: String {
            switch self {
            case .unavailable(let s): "not available on this Mac: \(s)"
            case .noSource(let s): "the photograph could not be read for finding: \(s)"
            case .failed(let s): "finding failed: \(s)"
            case .dropped: "a result for a frame or decode that is no longer open: dropped"
            }
        }
    }

    /// The detectors' names and pinned revisions, as the provenance records them.
    static let subjectDetector = "GenerateForegroundInstanceMaskRequest"
    static let personDetector = "GeneratePersonInstanceMaskRequest"
    static let peopleDetector = "GeneratePersonSegmentationRequest.accurate"
    static let revision = 1
    /// L_c (RFC-052 §4.4): a found picture is never larger.
    static let maxLongEdge = 4096
    /// **The rendition's long edge: 2048.** The two instance requests answer at the rendition's size, upscaled from a
    /// 512 × 512 model mask, so this is the found picture's size too. Measured (`tools/subject_find.sh --sizes`, this
    /// Mac, an M3 Max, 2026-11-13; five photographs, 24–60 MP RAWs and a JPEG; a process an edge): against 4096's mask,
    /// 2048's mean difference is 0.0002–0.0013 of full scale for 主体 (IoU at ½ 0.996–0.999) and 0.0007–0.0019 for a
    /// person (IoU 0.98–0.995, where the two runs number the same person alike); 1024's is 2–4 times that (a person's
    /// IoU 0.83–0.97). The cost hardly moves with it: the request 0.03–0.06 s warm (主体) and 0.13–0.53 s (人) from 1024
    /// to 4096, and the peak footprint is the RAW's decode (0.5–1.2 GB at any edge), not the mask's. 2048 is where the
    /// difference stops falling; 4096 would double the file and the bake's read for nothing the model saw.
    static let renditionLongEdge = 2048

    let detector: any MaskDetector
    let files: FoundMaskFiles
    let renditionLongEdge: Int
    private var focused: FindTag?
    private struct Memo { var tag: FindTag; var subject: FoundResult?; var people: PeopleResult? }
    private var memo: Memo?
    private var context: CIContext?

    init(detector: any MaskDetector = VisionDetector(), files: FoundMaskFiles = .shared,
         renditionLongEdge: Int = SubjectFinder.renditionLongEdge) {
        self.detector = detector; self.files = files; self.renditionLongEdge = renditionLongEdge
    }

    /// The frame and decode the page shows now; nil when no page is open (a driver's run: every result is taken).
    /// A result whose tag is not this when it lands is dropped, and the memo of another tag goes.
    func focus(_ tag: FindTag?) {
        focused = tag
        if let memo, memo.tag != tag { self.memo = nil }
    }

    // MARK: finding

    /// 主体 (and 背景, the same result with the part's invert): every foreground instance as one mask. `again` is
    /// 重新查找: the detector asked again, whatever the memo holds. Nil where nothing is found.
    func subject(_ source: FindSource, again: Bool = false) async throws -> FoundResult? {
        let tag = source.tag
        if !again, let memo, memo.tag == tag, let kept = memo.subject { return kept }
        let (image, fingerprint) = try rendition(source)
        let found: FoundPicture?
        do { found = try await detector.subject(image) } catch { throw Self.failure(error) }
        try landed(tag)
        guard let found else { return nil }
        let result = Self.result(found, what: .subject, instance: 0, detector: Self.subjectDetector, tag: tag, fingerprint: fingerprint)
        remember(tag) { $0.subject = result }
        return result
    }

    /// 人: each person and 全部人物, with the menu's squares. `again` as for `subject`.
    func people(_ source: FindSource, again: Bool = false) async throws -> PeopleResult {
        let tag = source.tag
        if !again, let memo, memo.tag == tag, let kept = memo.people { return kept }
        let (image, fingerprint) = try rendition(source)
        let persons: [FoundPicture], all: FoundPicture?
        do {
            persons = try await detector.persons(image)
            all = try await detector.people(image)
        } catch { throw Self.failure(error) }
        try landed(tag)
        let size = PixelSize(width: image.width, height: image.height)
        var allResult = all.map { Self.result($0, what: .people, instance: 0, detector: Self.peopleDetector, tag: tag, fingerprint: fingerprint) }
        var people: [PeopleResult.Person] = []
        for (i, p) in persons.enumerated() {
            let r = Self.result(p, what: .person, instance: i + 1, detector: Self.personDetector, tag: tag, fingerprint: fingerprint)
            guard let box = r.box else { continue }
            // A phantom: an instance 全部人物 does not lie over is not a person (`overlap`'s note).
            guard let a = allResult, a.box != nil, Self.overlap(r.picture, under: a.picture) >= Self.personOverlap else { continue }
            people.append(PeopleResult.Person(number: people.count + 1, found: r, thumbnail: Self.square(box, in: size)))
        }
        if allResult?.box == nil && people.isEmpty { allResult = nil }
        let result = PeopleResult(tag: tag, all: allResult, people: people)
        remember(tag) { $0.people = result }
        return result
    }

    // MARK: keeping

    /// A found result kept as the frame's file (`FoundMaskFiles.write`), and the part that names it: 背景 is the same
    /// file with the part's invert. Throws `FoundMaskFiles.Failure` where it cannot be written.
    func part(_ found: FoundResult, background: Bool = false, join: MaskPart.Join = .add) async throws -> MaskPart {
        let asset = try await files.write(found.picture, found.mask, frame: found.tag.frame)
        var mask = found.mask
        mask.invert = background
        return MaskPart.found(mask, asset: asset, join: join)
    }

    // MARK: the tag

    private func landed(_ tag: FindTag) throws {
        if let focused, focused != tag { throw Failure.dropped }
    }

    private func remember(_ tag: FindTag, _ change: (inout Memo) -> Void) {
        var m = memo?.tag == tag ? memo! : Memo(tag: tag)
        change(&m)
        memo = m
    }

    static func failure(_ error: Error) -> Failure {
        if let f = error as? Failure { return f }
        if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *), let v = error as? VisionError {
            switch v {
            case .unsupportedComputeDevice(let s), .unsupportedComputeStage(let s), .unsupportedRequest(let s),
                 .unsupportedRevision(let s), .invalidModel(let s): return .unavailable(s)
            default: return .failed("\(v)")
            }
        }
        let ns = error as NSError
        if ns.domain == VNErrorDomain, [VNErrorCode.unsupportedRevision.rawValue, VNErrorCode.unsupportedRequest.rawValue,
                                         VNErrorCode.unsupportedComputeStage.rawValue, VNErrorCode.unsupportedComputeDevice.rawValue,
                                         VNErrorCode.notImplemented.rawValue].contains(ns.code) {
            return .unavailable(ns.localizedDescription)
        }
        return .failed("\(error)")
    }

    // MARK: the result

    /// A detector's picture as a result: capped at L_c, its provenance, its box.
    static func result(_ picture: FoundPicture, what: FoundMask.What, instance: Int, detector: String, tag: FindTag,
                       fingerprint: String) -> FoundResult {
        let pic = capped(picture)
        let mask = FoundMask(what: what, instance: instance, invert: false, width: pic.width, height: pic.height,
                             detector: detector, revision: revision, system: system, fingerprint: fingerprint,
                             decodeGeometry: tag.geometry)
        return FoundResult(tag: tag, mask: mask, picture: pic, box: box(pic))
    }

    /// The system the detector ran on: "Version 27.0.1 (Build 26A434)".
    static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// A picture no larger than L_c on its long edge: averaged down by whole areas where it is larger (never seen
    /// from these requests at a rendition of 4096 or less; said, not assumed).
    static func capped(_ p: FoundPicture, maxLongEdge: Int = SubjectFinder.maxLongEdge) -> FoundPicture {
        let long = max(p.width, p.height)
        guard long > maxLongEdge else { return p }
        let k = Double(maxLongEdge) / Double(long)
        let w = max(1, Int((Double(p.width) * k).rounded())), h = max(1, Int((Double(p.height) * k).rounded()))
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * p.height / h, y1 = max(y0 + 1, (y + 1) * p.height / h)
            for x in 0..<w {
                let x0 = x * p.width / w, x1 = max(x0 + 1, (x + 1) * p.width / w)
                var sum = 0
                for yy in y0..<y1 { for xx in x0..<x1 { sum += Int(p.bytes[yy * p.width + xx]) } }
                out[y * w + x] = UInt8((Double(sum) / Double((y1 - y0) * (x1 - x0))).rounded())
            }
        }
        return FoundPicture(width: w, height: h, bytes: out)
    }

    /// The box of the texels at ½ or more, in S; nil where there are none.
    static func box(_ p: FoundPicture) -> MaskRect? {
        var x0 = p.width, y0 = p.height, x1 = -1, y1 = -1
        for y in 0..<p.height {
            let row = y * p.width
            for x in 0..<p.width where p.bytes[row + x] >= 128 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= 0 else { return nil }
        let w = Double(p.width), h = Double(p.height)
        return MaskRect(x: Double(x0) / w, y: Double(y0) / h, width: Double(x1 - x0 + 1) / w, height: Double(y1 - y0 + 1) / h)
    }

    /// **The phantom person** (M1c step 0d): on a street with nobody in it (`SampleSources/scene_raw_srgb.jpg`) the
    /// per-person request answered one soft "person" over the cars while 全部人物 — the segmentation, another model —
    /// was empty. So an instance is a person only where 全部人物 lies over it: **the share of the instance's covered
    /// texels (≥ ½) at which 全部人物, sampled at the same place in S, is ≥ ½, at least `personOverlap`**. 全部人物
    /// empty: nobody. Measured (`found_mask_selftest --shares`, section K, this Mac 2026-11-13, `plain_bund.jpg` and
    /// `tools/subject_find.sh`'s eight photographs): the 16 people's shares are 0.658–1.000 (a person half behind
    /// another is the low one); the two phantoms' are 0.000 — the street's cars, and on `032_GFX100RF…DSCF1220.RAF` a
    /// flock of pigeons (looked at: `build/masks-check/found/…/person-1-over.png`). 0.25 is far from both.
    static let personOverlap = 0.25

    /// The share of `instance`'s texels at ½ or more under which `all` (any size, stretched over S) is ½ or more; 0
    /// where the instance covers nothing.
    static func overlap(_ instance: FoundPicture, under all: FoundPicture) -> Double {
        var covered = 0, under = 0
        for y in 0..<instance.height {
            let ay = min(all.height - 1, Int((Double(y) + 0.5) / Double(instance.height) * Double(all.height)))
            for x in 0..<instance.width where instance.bytes[y * instance.width + x] >= 128 {
                covered += 1
                let ax = min(all.width - 1, Int((Double(x) + 0.5) / Double(instance.width) * Double(all.width)))
                if all.bytes[ay * all.width + ax] >= 128 { under += 1 }
            }
        }
        return covered == 0 ? 0 : Double(under) / Double(covered)
    }

    /// A square of the photograph's pixels round `box` (10 % beyond its longer side), moved inside the picture and no
    /// larger than its shorter side: the menu's thumbnail of a person.
    static func square(_ box: MaskRect, in size: PixelSize) -> MaskRect {
        let W = Double(size.width), H = Double(size.height)
        let side = min(max(box.width * W, box.height * H) * 1.1, min(W, H))
        let cx = (box.x + box.width / 2) * W, cy = (box.y + box.height / 2) * H
        let x = min(max(cx - side / 2, 0), W - side), y = min(max(cy - side / 2, 0), H - side)
        return MaskRect(x: x / W, y: y / H, width: side / W, height: side / H)
    }

    // MARK: the rendition

    /// The source in S, display-referred, 8-bit sRGB, at `renditionLongEdge` at most; and its fingerprint (32 hex of
    /// SHA-256 over its RGBA bytes — what the detector was handed, exactly).
    func rendition(_ source: FindSource) throws -> (CGImage, String) {
        let ctx = readied()
        defer { ctx.clearCaches() }
        let edge = renditionLongEdge
        var image: CIImage
        var sourcePixels: Double? = nil
        if source.isRAW {
            if let proxy = source.proxy, let kept = RawProxy.read(proxy), max(kept.header.width, kept.header.height) >= edge {
                image = RawExposure.scaled(RawProxy.image(kept.header, pixels: kept.pixels), toLongEdge: edge)
            } else {
                guard let prepared = RawExposure.prepare(source.url, settings: source.decode, longEdge: edge) else {
                    throw Failure.noSource(source.url.lastPathComponent)
                }
                image = prepared.image
                sourcePixels = prepared.sourcePixels
            }
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            guard let s = CGImageSourceCreateWithURL(source.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let small = CGImageSourceCreateThumbnailAtIndex(s, 0, options as CFDictionary) else {
                throw Failure.noSource(source.url.lastPathComponent)
            }
            image = CIImage(cgImage: small)
        }
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw Failure.noSource("an empty picture") }
        image = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // In bands, as `FrameDecoder` renders a RAW made smaller: 2 MP of the decode a band (its header's measure).
        let bands = min(h, max(1, Int(((sourcePixels ?? 0) / 2_000_000).rounded(.up)), Int((Double(w * h) / 4_000_000).rounded(.up))))
        bytes.withUnsafeMutableBytes { raw in
            for b in 0..<bands {
                autoreleasepool {
                    let r0 = h * b / bands, r1 = h * (b + 1) / bands
                    ctx.render(image, toBitmap: raw.baseAddress! + r0 * rowBytes, rowBytes: rowBytes,
                               bounds: CGRect(x: 0, y: h - r1, width: w, height: r1 - r0), format: .RGBA8, colorSpace: srgb)
                }
            }
        }
        var hash = SHA256()
        bytes.withUnsafeBytes { hash.update(bufferPointer: $0) }
        let fingerprint = hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: srgb,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.noSource("the rendition")
        }
        return (cg, fingerprint)
    }

    private func readied() -> CIContext {
        if let context { return context }
        let c = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                    .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
        context = c
        return c
    }
}

// MARK: - Vision

/// The three requests, revision 1 pinned (`SubjectFinder`'s header).
struct VisionDetector: MaskDetector {
    func subject(_ image: CGImage) async throws -> FoundPicture? {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) else { throw SubjectFinder.Failure.unavailable("this system") }
        let handler = ImageRequestHandler(image)
        guard let o = try await handler.perform(GenerateForegroundInstanceMaskRequest(.revision1)), !o.allInstances.isEmpty else { return nil }
        return try Self.picture(o.generateScaledMask(for: o.allInstances, scaledToImageFrom: handler))
    }

    func persons(_ image: CGImage) async throws -> [FoundPicture] {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) else { throw SubjectFinder.Failure.unavailable("this system") }
        let handler = ImageRequestHandler(image)
        guard let o = try await handler.perform(GeneratePersonInstanceMaskRequest(.revision1)) else { return [] }
        return try o.allInstances.sorted().map { try Self.picture(o.generateScaledMask(for: IndexSet(integer: $0), scaledToImageFrom: handler)) }
    }

    /// 全部人物 through the Objective-C request, `VNGeneratePersonSegmentationRequest` (the same model, revision 1
    /// pinned, `.accurate`): the Swift request's matte can be read as pixels only through `pixelBuffer` (macOS 27) or
    /// `cgImage`, which came back 32 bits a pixel here for an 8-bit request (measured 2026-11-13) — a conversion this
    /// would have to undo. The `VN…` observation hands the `CVPixelBuffer` itself, on every system the app runs on.
    func people(_ image: CGImage) async throws -> FoundPicture? {
        let request = VNGeneratePersonSegmentationRequest()
        request.revision = VNGeneratePersonSegmentationRequestRevision1
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let o = request.results?.first else { return nil }
        return try Self.picture(o.pixelBuffer)
    }

    /// A one-component mask (8-bit or 32-bit float) as 8 bits, rows tight: v ↦ round(255 · clamp(v, 0, 1)).
    static func picture(_ b: CVPixelBuffer) throws -> FoundPicture {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), row = CVPixelBufferGetBytesPerRow(b)
        guard let base = CVPixelBufferGetBaseAddress(b) else { throw SubjectFinder.Failure.failed("an empty mask") }
        var out = [UInt8](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(b) {
        case kCVPixelFormatType_OneComponent8:
            // Through the array's own buffer: `&out[y * w]` hands memcpy a pointer Swift promises for one element only
            // (an inout to the subscript), and w bytes written through it were the heap corruption two `--masks-check`
            // runs crashed on after 人 (2026-11-13: "memory corruption of free block", in the next view's CALayer).
            out.withUnsafeMutableBytes { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w, base + y * row, w) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let r = (base + y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = UInt8((min(max(r[x], 0), 1) * 255).rounded()) }
            }
        case let f: throw SubjectFinder.Failure.failed("a mask of pixel format \(f)")
        }
        return FoundPicture(width: w, height: h, bytes: out)
    }
}

/// A detector that is not there: every request `unavailable`, as on a Mac whose Vision cannot run them (gate 11's
/// path, forced for a check and for the interface's "not available on this Mac").
struct UnavailableDetector: MaskDetector {
    var why = "this Mac's Vision does not run the request"
    func subject(_ image: CGImage) async throws -> FoundPicture? { throw SubjectFinder.Failure.unavailable(why) }
    func persons(_ image: CGImage) async throws -> [FoundPicture] { throw SubjectFinder.Failure.unavailable(why) }
    func people(_ image: CGImage) async throws -> FoundPicture? { throw SubjectFinder.Failure.unavailable(why) }
}
