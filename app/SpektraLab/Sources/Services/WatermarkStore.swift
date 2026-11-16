//  WatermarkStore.swift — the person's watermarks (水印): PNGs with transparency, kept by the app.
//  PRD-8 §4.1, RFC-067 §1–2; the Settings section is `Mac/Settings/MacSettingsWatermarks.swift`.
//
//  - **Files, in a fixed on-disk shape** that must not move: `Watermarks/<uuid>.png`
//    holds the person's bytes as given; `index.json` beside them is a **bare JSON array** (no version field: the
//    shape, fixed) of `{id, name, added, w, h, sha256}`, pretty-printed with sorted keys, every write atomic.
//    The folder is under the app's own `Application Support/<bundle id>/` (`MAC-LIBRARY-DATA.md` §3), named
//    by the bundle id the build runs as (a debug build's differs), handed in by the app (`AppServices`); nothing here
//    names it. An index that cannot be read is rebuilt from the folder (a file's name is its id; its name becomes
//    "Watermark N"); a file the index lacks is taken back in the same way, and an entry whose file is gone is dropped.
//  - **Thumbnails.** A 256 px copy (long side), premultiplied, in `Caches/<bundle id>/Watermarks/<uuid>.png`, made
//    again whenever it is missing.
//  - **The check** (`validate`), in RFC-067 §2's order: the PNG signature (the content, never the
//    extension); ImageIO decodes it and it has an alpha channel (or a `tRNS` chunk); at least one pixel is not
//    opaque (scanned on a ≤ 1024 px copy); the long side ≤ 8192 px and the file ≤ 50 MB. **One exception**: a file
//    on disk past 50 MB is not read whole to be refused (reading it all only to refuse it is the waste): its
//    first 8 bytes and its header are read, and it is refused as too large when the signature says PNG (as not a PNG
//    otherwise). Every other file meets the four checks in that order.
//  - **The same bytes twice are one mark** (deduped by SHA-256: a second copy is never kept): an add
//    whose SHA-256 the library has already names that mark (`Added.existing`), and the page selects it and says so.
//  - **Pixels for a renderer.** `bitmap(_:width:)` is `nonisolated`: the mark decoded into sRGB (an embedded profile
//    honoured, 16 bit taken to 8), premultiplied 8-bit RGBA, resampled once (Lanczos, vImage's high-quality scale) to
//    the width asked for, and cached by (id, sha256, width) within a small budget. The full-size decode is not kept.
//  - **Use.** How many photographs place a mark is not this store's to know (the edits are the library's):
//    `usageCount` is handed in. Nil answers 0.
//
//  No UIKit and no engine: `tools/watermark_store_selftest.swift` holds it on the Mac.

import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Observation

/// Why a picture is not taken as a mark, in the order the check finds it (RFC-067 §2).
enum WatermarkRefusal: Error, Equatable, Sendable {
    /// 1. The first 8 bytes are not the PNG signature.
    case notPNG
    /// 2. ImageIO cannot decode it.
    case unreadable
    /// 2. No alpha channel and no `tRNS` chunk.
    case noAlphaChannel
    /// 3. Every pixel is opaque.
    case allOpaque
    /// 4. Past the long side's or the file's limit.
    case tooLarge(longSide: Int, bytes: Int)
    /// The file could not be read: no check was reached.
    case couldNotRead
    /// The file could not be written.
    case couldNotKeep

    /// The alert's message: its first line always the rule; the second why this picture breaks it.
    var message: String {
        let rule = L("Only a PNG with a transparent background.")
        switch self {
        case .notPNG, .unreadable: return rule
        case .noAlphaChannel, .allOpaque: return rule + "\n" + L("This image has no transparent area.")
        case .tooLarge(let longSide, let bytes):
            if longSide > WatermarkStore.maxLongSide {
                return L("This PNG is \(Fmt.thousands(longSide)) px on its long side. A watermark can be up to \(Fmt.thousands(WatermarkStore.maxLongSide)) px.")
            }
            let mb = Int((Double(bytes) / 1_048_576).rounded(.up))
            return L("This PNG is \(mb) MB. A watermark can be up to \(WatermarkStore.maxBytes / 1_048_576) MB.")
        case .couldNotRead: return L("The picture could not be read.")
        case .couldNotKeep: return L("The watermark could not be saved.")
        }
    }
}

/// What an add made: a new mark, or the one the library already holds for the same bytes.
enum WatermarkAdded: Equatable, Sendable {
    case new(WatermarkMark)
    case existing(WatermarkMark)
    var mark: WatermarkMark {
        switch self {
        case .new(let m), .existing(let m): m
        }
    }
}

@MainActor
@Observable
final class WatermarkStore {
    /// Newest first (PRD-8 §4.1; no reorder in v1, W4).
    private(set) var marks: [WatermarkMark] = []
    /// The 256 px thumbnails loaded so far.
    private(set) var thumbnails: [UUID: CGImage] = [:]

    /// How many photographs place this mark (the library's edits; wired by the app). Nil answers 0.
    @ObservationIgnored var usageCount: ((UUID) -> Int)?

    /// Where the PNGs and `index.json` live.
    nonisolated let folder: URL
    /// Where the thumbnails live.
    nonisolated let caches: URL
    @ObservationIgnored nonisolated private let shelf = Shelf()
    @ObservationIgnored private var loading: Set<UUID> = []

    nonisolated static let folderName = "Watermarks"
    nonisolated static let indexName = "index.json"
    nonisolated static let maxLongSide = 8192
    nonisolated static let maxBytes = 50 * 1_048_576
    nonisolated static let thumbnailSide = 256
    /// The ≤ 1024 px copy the transparency scan reads.
    nonisolated static let scanSide = 1024
    nonisolated static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The app's own folders: `<root>/Watermarks` (the root is the app's Application Support folder, by its bundle id:
    /// `ImportService.root`), and the thumbnails under the app's own Caches folder.
    nonisolated static func folder(in root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }
    nonisolated static var defaultCaches: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.spektralab.mac"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(id, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    /// `folder` nil keeps nothing past the run (a check, a drive): a folder of its own under the temporary files.
    init(folder: URL?, caches: URL? = nil) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("watermarks-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder ?? scratch.appendingPathComponent("marks", isDirectory: true)
        self.caches = caches ?? (folder == nil ? scratch.appendingPathComponent("caches", isDirectory: true) : Self.defaultCaches)
        load()
    }

    // MARK: - reading the folder

    private var indexURL: URL { folder.appendingPathComponent(Self.indexName) }
    nonisolated func fileURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".png") }
    nonisolated func thumbnailURL(_ id: UUID) -> URL { caches.appendingPathComponent(id.uuidString + ".png") }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The index as kept; an unreadable one is rebuilt from the folder, and the two are made to agree. A folder that
    /// does not exist is not made until a mark is added: a library that never had a mark is the files it was.
    func load() {
        let fm = FileManager.default
        var list: [WatermarkMark] = []
        var rewrite = false
        if let data = try? Data(contentsOf: indexURL), let read = try? Self.decoder.decode([WatermarkMark].self, from: data) {
            list = read
        } else if fm.fileExists(atPath: indexURL.path) {
            rewrite = true      // unreadable: rebuilt below from the files
        }
        // An entry whose file is gone goes; one id once.
        var seen = Set<UUID>()
        let kept = list.filter { fm.fileExists(atPath: fileURL($0.id).path) && seen.insert($0.id).inserted }
        if kept.count != list.count { rewrite = true }
        list = kept
        // A file the index lacks (an unreadable index, a write cut off between the file and the index).
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url -> (UUID, URL, Date)? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !seen.contains(id) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return (id, url, date)
            }
            .sorted { $0.2 < $1.2 }
        for (id, url, date) in files {
            guard let data = try? Data(contentsOf: url), let size = Self.pixelSize(data) else { continue }
            list.append(WatermarkMark(id: id, name: L("Watermark \(list.count + 1)"), added: date,
                                      w: size.w, h: size.h, sha256: Self.sha256(data)))
            rewrite = true
        }
        marks = Self.ordered(list)
        publish()
        if rewrite { saveIndex() }
    }

    private static func ordered(_ list: [WatermarkMark]) -> [WatermarkMark] {
        list.sorted { $0.added != $1.added ? $0.added > $1.added : $0.id.uuidString < $1.id.uuidString }
    }

    @discardableResult
    private func saveIndex() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(marks).write(to: indexURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The list the off-main readers see.
    private func publish() { shelf.set(Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0) })) }

    func mark(_ id: UUID) -> WatermarkMark? { marks.first { $0.id == id } }

    /// The names as the model takes them (`WatermarkNames`): a placement's mark is there when it is named here. Any
    /// thread (the renderers' own list).
    nonisolated var namesNow: WatermarkNames { WatermarkNames(names: shelf.all().mapValues(\.name)) }

    // MARK: - adding, renaming, deleting

    /// A PNG on disk (the open panel's, a drop onto the grid), checked and kept as a new mark named by its file. Read
    /// off the main actor; a file past `maxBytes` is never read whole (the header).
    @discardableResult
    func add(fileAt url: URL) async -> Result<WatermarkAdded, WatermarkRefusal> {
        let name = url.deletingPathExtension().lastPathComponent
        let read = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
        switch read {
        case .failure(let refusal): return .failure(refusal)
        case .success(let data): return await add(data, name: name)
        }
    }

    /// A file's bytes for the check: whole where it is within the limit; past it, refused from its first bytes and
    /// its header without reading the rest.
    nonisolated static func read(_ url: URL) -> Result<Data, WatermarkRefusal> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .failure(.couldNotRead) }
        if size > maxBytes {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.couldNotRead) }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 8)) ?? Data()
            guard head.count == 8, Array(head) == pngSignature else { return .failure(.notPNG) }
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            return .failure(.tooLarge(longSide: max(w, h), bytes: size))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.couldNotRead) }
        return .success(data)
    }

    /// Checks the bytes and keeps them as a new mark, newest first — or names the mark that already holds the same
    /// bytes. The check, the hash, the file and the thumbnail are made off the main actor. `name` nil: "Watermark N".
    @discardableResult
    func add(_ data: Data, name: String?) async -> Result<WatermarkAdded, WatermarkRefusal> {
        if let same = existing(Self.sha256(data)) { return .success(.existing(same)) }
        let id = UUID(), file = fileURL(id), thumb = thumbnailURL(id), caches = caches
        let made = await Task.detached(priority: .userInitiated) {
            Self.keep(data, to: file, thumbnail: thumb, caches: caches)
        }.value
        return finish(made, id: id, name: name, added: Date())
    }

    /// `add`, on the calling thread: a check's marks, a drive's.
    @discardableResult
    func addNow(_ data: Data, name: String?, added: Date = Date()) -> Result<WatermarkAdded, WatermarkRefusal> {
        if let same = existing(Self.sha256(data)) { return .success(.existing(same)) }
        let id = UUID()
        return finish(Self.keep(data, to: fileURL(id), thumbnail: thumbnailURL(id), caches: caches), id: id, name: name, added: added)
    }

    /// The mark whose file is these bytes, where the library has one.
    private func existing(_ sha256: String) -> WatermarkMark? { marks.first { $0.sha256 == sha256 } }

    private func finish(_ made: Result<Kept, WatermarkRefusal>, id: UUID, name: String?, added: Date)
        -> Result<WatermarkAdded, WatermarkRefusal> {
        switch made {
        case .failure(let refusal): return .failure(refusal)
        case .success(let kept):
            // Two adds of the same bytes at once: the second finds the first's mark here.
            if let same = existing(kept.sha256) {
                try? FileManager.default.removeItem(at: fileURL(id))
                try? FileManager.default.removeItem(at: thumbnailURL(id))
                return .success(.existing(same))
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mark = WatermarkMark(id: id, name: trimmed.isEmpty ? L("Watermark \(marks.count + 1)") : trimmed,
                                     added: added, w: kept.w, h: kept.h, sha256: kept.sha256)
            marks = Self.ordered(marks + [mark])
            if let thumbnail = kept.thumbnail { thumbnails[id] = thumbnail }
            publish()
            guard saveIndex() else {
                // The index could not take it: the file goes too, so the two never disagree.
                remove(id)
                return .failure(.couldNotKeep)
            }
            return .success(.new(mark))
        }
    }

    /// A new name; blank keeps the old one.
    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = marks.firstIndex(where: { $0.id == id }), marks[i].name != trimmed else { return }
        marks[i].name = trimmed
        publish()
        saveIndex()
    }

    /// The file, its thumbnail and its entry go, for good (no Undo, PRD-8 §4.1). Edits that place it keep their
    /// placement and draw nothing for it; their rows say the mark is missing.
    func delete(_ id: UUID) {
        remove(id)
        saveIndex()
    }

    private func remove(_ id: UUID) {
        marks.removeAll { $0.id == id }
        thumbnails[id] = nil
        publish()
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: thumbnailURL(id))
        shelf.forget(id)
    }

    /// How many photographs place it; 0 when nobody has said how to count.
    func usage(of id: UUID) -> Int { usageCount?(id) ?? 0 }

    // MARK: - thumbnails

    /// Loads the thumbnail into `thumbnails`: from the cache, or made again from the file.
    func loadThumbnail(_ id: UUID) async {
        guard thumbnails[id] == nil, !loading.contains(id), mark(id) != nil else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let file = fileURL(id), thumb = thumbnailURL(id), caches = caches
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            if let data = try? Data(contentsOf: thumb), let cached = Self.decodeSRGB(data) { return cached }
            guard let data = try? Data(contentsOf: file), let full = Self.decodeSRGB(data) else { return nil }
            let small = Self.thumbnail(of: full)
            if let small { Self.writePNG(small, to: thumb, caches: caches) }
            return small
        }.value
        if let image, mark(id) != nil { thumbnails[id] = image }
    }

    // MARK: - pixels for a renderer, off the main actor

    /// The mark's pixels: sRGB, premultiplied 8-bit RGBA, `width` px wide (nil: as stored; the height kept to the
    /// PNG's aspect), resampled once with a Lanczos kernel. Nil when the mark is not in the library (deleted) or its
    /// file cannot be read. Cached by (id, sha256, width).
    nonisolated func bitmap(_ id: UUID, width: Int? = nil) -> CGImage? {
        guard let mark = shelf.get(id) else { return nil }
        let w = max(1, width ?? mark.w)
        let key = BitmapKey(id: id, sha256: mark.sha256, width: w)
        if let hit = shelf.cached(key) { return hit }
        guard let data = try? Data(contentsOf: fileURL(id)), let full = Self.decodeSRGB(data) else { return nil }
        let image = w == full.width ? full : Self.resample(full, width: w)
        if let image { shelf.cache(image, for: key) }
        return image
    }

    /// The mark as the library holds it, for a renderer (its aspect, its hash); nil when deleted.
    nonisolated func info(_ id: UUID) -> WatermarkMark? { shelf.get(id) }

    // MARK: - the check

    struct Checked: Equatable, Sendable { let w: Int; let h: Int }

    /// RFC-067 §2's four checks, in order.
    nonisolated static func validate(_ data: Data) -> Result<Checked, WatermarkRefusal> {
        // 1. The signature: the content says PNG, whatever the file is called.
        guard data.count >= 8, Array(data.prefix(8)) == pngSignature else { return .failure(.notPNG) }
        // 2. ImageIO reads it, and it carries alpha.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return .failure(.unreadable) }
        let opaqueInfo: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        if opaqueInfo.contains(image.alphaInfo) && !hasTRNS(data) { return .failure(.noAlphaChannel) }
        // 3. Some pixel lets the picture through.
        guard let scan = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: scanSide,
        ] as CFDictionary) ?? (max(image.width, image.height) <= scanSide ? image : nil)
        else { return .failure(.unreadable) }
        guard let transparent = hasTransparency(scan) else { return .failure(.unreadable) }
        if !transparent { return .failure(.allOpaque) }
        // 4. The limits.
        let longSide = max(image.width, image.height)
        if longSide > maxLongSide || data.count > maxBytes { return .failure(.tooLarge(longSide: longSide, bytes: data.count)) }
        return .success(Checked(w: image.width, h: image.height))
    }

    /// A `tRNS` chunk before the image data: a palette or grey PNG with a transparent colour.
    nonisolated static func hasTRNS(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 8
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(bytes: bytes[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            if type == "tRNS" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            i += 12 + length
        }
        return false
    }

    /// Whether any pixel's alpha is under 255; nil when it cannot be drawn.
    nonisolated static func hasTransparency(_ image: CGImage) -> Bool? {
        guard let ctx = rgbaContext(image.width, image.height) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let line = p + y * row
            for x in 0..<image.width where line[x * 4 + 3] < 255 { return true }
        }
        return false
    }

    // MARK: - decode, resample, write

    struct Kept: Sendable {
        let w: Int, h: Int, sha256: String
        let thumbnail: CGImage?
    }

    /// Check, hash and write the bytes as they are, then the thumbnail.
    nonisolated static func keep(_ data: Data, to file: URL, thumbnail: URL, caches: URL) -> Result<Kept, WatermarkRefusal> {
        let checked: Checked
        switch validate(data) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let c): checked = c
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return .failure(.couldNotKeep)
        }
        var small: CGImage?
        if let full = decodeSRGB(data) {
            small = self.thumbnail(of: full)
            if let small { writePNG(small, to: thumbnail, caches: caches) }
        }
        return .success(Kept(w: checked.w, h: checked.h, sha256: sha256(data), thumbnail: small))
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The PNG's pixel size, read from its header without decoding it.
    nonisolated static func pixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    nonisolated static func rgbaContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    /// The file's pixels in sRGB (an embedded profile converted; 16 bit to 8), premultiplied RGBA.
    nonisolated static func decodeSRGB(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let ctx = rgbaContext(image.width, image.height) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// `image` (premultiplied RGBA, as `decodeSRGB` makes it) at `width` px, its aspect kept: vImage's high-quality
    /// scale, a Lanczos kernel, on premultiplied values.
    nonisolated static func resample(_ image: CGImage, width: Int) -> CGImage? {
        let w = max(1, width)
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        guard let from = rgbaContext(image.width, image.height), let to = rgbaContext(w, h) else { return nil }
        from.setBlendMode(.copy)
        from.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let src = from.data, let dst = to.data else { return nil }
        var s = vImage_Buffer(data: src, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width), rowBytes: from.bytesPerRow)
        var d = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: to.bytesPerRow)
        // The four channels are scaled alike, so ARGB's routine serves RGBA.
        guard vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
        return to.makeImage()
    }

    /// The 256 px copy (long side); a smaller mark as it is.
    nonisolated static func thumbnail(of full: CGImage) -> CGImage? {
        let long = max(full.width, full.height)
        guard long > thumbnailSide else { return full }
        let w = full.width >= full.height ? thumbnailSide : max(1, Int((Double(full.width) * Double(thumbnailSide) / Double(long)).rounded()))
        return resample(full, width: w)
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL, caches: URL) {
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    // MARK: - what the off-main readers share

    struct BitmapKey: Hashable, Sendable {
        let id: UUID
        let sha256: String
        let width: Int
    }

    /// The library's entries and the resampled bitmaps, behind a lock: the renderers read them from any thread.
    private final class Shelf: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UUID: WatermarkMark] = [:]
        private var bitmaps: [BitmapKey: CGImage] = [:]
        private var order: [BitmapKey] = []
        private var bytes = 0
        /// What the resampled bitmaps may hold at once; the oldest asked for go first.
        static let budget = 96 * 1_048_576

        func set(_ new: [UUID: WatermarkMark]) { lock.withLock { entries = new } }
        func get(_ id: UUID) -> WatermarkMark? { lock.withLock { entries[id] } }
        func all() -> [UUID: WatermarkMark] { lock.withLock { entries } }

        func cached(_ key: BitmapKey) -> CGImage? {
            lock.withLock {
                guard let hit = bitmaps[key] else { return nil }
                order.removeAll { $0 == key }
                order.append(key)
                return hit
            }
        }

        func cache(_ image: CGImage, for key: BitmapKey) {
            lock.withLock {
                guard bitmaps[key] == nil else { return }
                bitmaps[key] = image
                order.append(key)
                bytes += image.bytesPerRow * image.height
                while bytes > Self.budget, order.count > 1 {
                    let old = order.removeFirst()
                    if let gone = bitmaps.removeValue(forKey: old) { bytes -= gone.bytesPerRow * gone.height }
                }
            }
        }

        func forget(_ id: UUID) {
            lock.withLock {
                for key in order where key.id == id {
                    if let gone = bitmaps.removeValue(forKey: key) { bytes -= gone.bytesPerRow * gone.height }
                }
                order.removeAll { $0.id == id }
            }
        }
    }
}

/// The renderers read the library through `WatermarkPixels` (`WatermarkComposite`): `bitmap` and `info` are its
/// `nonisolated` reads.
extension WatermarkStore: WatermarkPixels {}
