//  ThumbnailStore.swift — pictures for the page, at the size the page shows them.
//
//  The frontend's share of RAM-first (RFC-036 §6.3's `r_app`). A library tile
//  is 130 pt; decoding the picture behind it at full size to draw 390 pixels of
//  it would cost a hundred times the memory the tile needs, on every tile. So:
//
//  - **ImageIO makes the thumbnail at the asked size**, straight from the file
//    (`kCGImageSourceThumbnailMaxPixelSize`): the full bitmap is never held.
//  - **Decoding is off the main thread**, inside its own autorelease pool, so a
//    scroll does not pile up autoreleased buffers (the bench leaked 72 → 646 MB
//    over four photos that way: the handoff, §7).
//  - **The cache is bounded by bytes**, not by count, and is emptied on a
//    memory warning — before the engine is asked to give anything back.
//
//  The scheduler owns renders; this owns only what is already a picture on
//  disk (a preview copy, a bundled demo frame).

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A RAW's embedded preview is its camera's own JPEG, made in the camera's picture style: a camera set
/// to a black-and-white style embeds a grey preview of a colour RAW (the owner's Leica Q3, 2026-11-05:
/// the crop page's "before the film" picture was black and white; `L1026319.DNG`'s embedded preview
/// measured 0.0 mean chroma of 255, its RAW decoded 54.5). The preview stands for the photo only where
/// it keeps the photo's colour: a grey preview of a colour RAW is the camera's look, and the RAW is
/// decoded in its place by Core Image's RAW filter (`ImportService.rawDecoded`), off the main thread,
/// once per size. Not by ImageIO's `kCGImageSourceCreateThumbnailFromImageAlways`: asked for 3,000 px
/// or more of that Q3 DNG it returns the camera's full-size embedded JPEG, grey (measured: 1,600 px
/// decoded, chroma 54.4; 3,000, 5,000 and 9,520 px chroma 0.0). A monochrome sensor's RAW (a Leica Monochrom, whose model says so, or a DNG ImageIO
/// does not call RGB) keeps its grey preview. A toned black-and-white style is not caught.
enum RawPreviewColour {
    /// Whether `preview` is grey while the RAW in `source` holds colour.
    static func lost(_ preview: CGImage, in source: CGImageSource) -> Bool {
        isGrey(preview) && holdsColour(source)
    }

    static func holdsColour(_ source: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelRGB as String) else { return false }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let camera = (tiff?[kCGImagePropertyTIFFModel] as? String ?? "").lowercased()
        return !camera.contains("monochrom")
    }

    /// The picture drawn at 32 px: its mean of max − min channel, of 255, under 1 (a JPEG of a grey
    /// picture measures 0.0; a colour photograph tens).
    static func isGrey(_ image: CGImage) -> Bool {
        let w = 32, h = max(1, 32 * image.height / max(image.width, 1))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return false }
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = px[i], g = px[i + 1], b = px[i + 2]
            sum += Int(max(r, g, b)) - Int(min(r, g, b))
        }
        return Double(sum) / Double(w * h) < 1
    }
}

final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.spektralab.thumbnails", qos: .userInitiated, attributes: .concurrent)
    /// The sizes each picture has been made at, so one of them can stand in
    /// while another is decoded (`cachedAny`). The cache may have dropped any
    /// of them; this only says where to look.
    private let lock = NSLock()
    private var sizes: [String: Set<Int>] = [:]

    /// 64 MB of decoded pixels: about 110 tiles at 3×, or four canvases.
    init(byteLimit: Int = 64 << 20) {
        cache.totalCostLimit = byteLimit
    }

    static func url(for picture: PictureRef) -> URL? {
        switch picture {
        case .sample(let name):
            // `build/SampleFrames` is copied into the bundle as a folder.
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "SampleFrames")
        case .file(let url):
            url
        case .rendered:
            nil
        }
    }

    private static func key(_ picture: PictureRef, _ maxPixel: Int) -> NSString {
        switch picture {
        case .sample, .file: "\(name(picture))@\(maxPixel)" as NSString
        case .rendered(let id): "r:\(id.uuidString)" as NSString
        }
    }

    /// The picture's own name in the cache, without a size.
    private static func name(_ picture: PictureRef) -> String {
        switch picture {
        case .sample(let name): "s:\(name)"
        case .file(let url): "f:\(url.path)"
        case .rendered(let id): "r:\(id.uuidString)"
        }
    }

    /// The picture at whatever size the cache still has it, the largest
    /// first: something to draw at once while the size wanted is decoded. A
    /// page that changes the size it asks for — a pinch, a new cut — would
    /// otherwise show its ground for the length of a decode.
    func cachedAny(_ picture: PictureRef) -> UIImage? {
        if case .rendered(let id) = picture { return RenderedPictures.shared.image(id) }
        lock.lock()
        let known = sizes[Self.name(picture)] ?? []
        lock.unlock()
        for size in known.sorted(by: >) {
            if let hit = cache.object(forKey: Self.key(picture, size)) { return hit }
        }
        return nil
    }

    /// A picture already in the cache, without waiting. A develop held in
    /// memory is served as it is, at its own size: it is already a picture.
    func cached(_ picture: PictureRef, maxPixel: Int) -> UIImage? {
        if case .rendered(let id) = picture { return RenderedPictures.shared.image(id) }
        return cache.object(forKey: Self.key(picture, maxPixel))
    }

    /// The picture with its long edge at `maxPixel` pixels at most.
    func image(_ picture: PictureRef, maxPixel: Int) async -> UIImage? {
        if let hit = cached(picture, maxPixel: maxPixel) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.load(picture, maxPixel: maxPixel)) }
        }
    }

    /// The same, on the calling thread. The snapshot harness uses it, so a page
    /// is complete when it is captured; a page never should.
    func load(_ picture: PictureRef, maxPixel: Int) -> UIImage? {
        if case .rendered(let id) = picture { return RenderedPictures.shared.image(id) }
        let key = Self.key(picture, maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = Self.url(for: picture) else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            // A RAW file carries its camera's own preview, and that is what a
            // tile should be made from: asking ImageIO to make the thumbnail
            // "from the image, always" develops the whole RAW to draw 390
            // pixels of it. So a RAW uses its embedded preview, and is decoded
            // only when that preview is too small to show (some cameras embed
            // 160 px). Everything else is scaled from the image itself, which
            // for JPEG and HEIC ImageIO does without the full bitmap.
            let isRAW = (CGImageSourceGetType(source) as String?)
                .flatMap { UTType($0) }?.conforms(to: .rawImage) ?? false
            func thumbnail(fromImage: Bool) -> CGImage? {
                let options: [CFString: Any] = [
                    (fromImage ? kCGImageSourceCreateThumbnailFromImageAlways
                               : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            var made = thumbnail(fromImage: !isRAW)
            if isRAW, let preview = made {
                if RawPreviewColour.lost(preview, in: source) {
                    // Decoded by Core Image's RAW filter: ImageIO's "from the image" hands back the
                    // same embedded JPEG at 3,000 px and over (`RawPreviewColour`).
                    made = ImportService.rawDecoded(url, longEdge: maxPixel) ?? preview
                } else if max(preview.width, preview.height) < min(maxPixel, 512) / 2 {
                    made = thumbnail(fromImage: true) ?? preview
                }
            }
            guard let cg = made else { return nil }
            let image = UIImage(cgImage: cg)
            cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
            lock.lock()
            sizes[Self.name(picture), default: []].insert(maxPixel)
            lock.unlock()
            return image
        }
    }

    /// A memory warning: everything goes. A tile re-decodes in a few
    /// milliseconds; a kill loses the session.
    func trim() {
        cache.removeAllObjects()
        lock.lock()
        sizes.removeAll()
        lock.unlock()
    }
}

/// Develops the engine has just handed over, held for the page that asked:
/// the develop page's canvas between edits. One picture per page at most (a
/// 2,400 px canvas is 35 MB at 16 bits), put by the page's session and taken
/// away by it; emptied with the picture cache on a memory warning — the page
/// then shows the frame's kept develop until its next one lands.
final class RenderedPictures: @unchecked Sendable {
    static let shared = RenderedPictures()
    private let lock = NSLock()
    private var images: [UUID: UIImage] = [:]

    func put(_ image: UIImage) -> PictureRef {
        let id = UUID()
        lock.lock(); images[id] = image; lock.unlock()
        return .rendered(id)
    }

    func image(_ id: UUID) -> UIImage? { lock.lock(); defer { lock.unlock() }; return images[id] }

    func remove(_ picture: PictureRef?) {
        guard case .rendered(let id)? = picture else { return }
        lock.lock(); images[id] = nil; lock.unlock()
    }

    func removeAll() { lock.lock(); images.removeAll(); lock.unlock() }
}

/// A picture on a page: decoded at the size it is shown, never larger.
struct FramePicture: View {
    let picture: PictureRef
    /// The long edge it is drawn at, in points; the store decodes at this × the
    /// screen's scale, rounded up to a step so nearby sizes share one decode.
    let pointSize: CGFloat
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var scale
    @Environment(\.isSnapshot) private var isSnapshot
    /// The space a page shows it in (`CanvasGamut`): Develop's canvas, the Export page's preview.
    @Environment(\.gamutProof) private var gamutProof
    @State private var image: UIImage?

    private var maxPixel: Int? { PictureLoading.maxPixel(points: pointSize, scale: scale) }

    var body: some View {
        ZStack {
            Theme.plot
            if let shown = image ?? ThumbnailStore.shared.cachedAny(picture) ?? (isSnapshot ? maxPixel.flatMap { ThumbnailStore.shared.load(picture, maxPixel: $0) } : nil) {
                Image(uiImage: GamutProof.shared.proofed(shown, gamutProof)).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: "\(picture)-\(maxPixel ?? 0)") {
            guard !isSnapshot, let maxPixel else { return }
            // The picture shown stays until the one for this size lands (a
            // zoom step would show the ground for the length of a decode).
            if let made = await PictureLoading.picture(picture, maxPixel: maxPixel) { image = made }
        }
    }
}

private struct IsSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the snapshot harness: a page draws complete and still —
    /// pictures decoded at once, nothing animating.
    var isSnapshot: Bool {
        get { self[IsSnapshotKey.self] }
        set { self[IsSnapshotKey.self] = newValue }
    }
}
