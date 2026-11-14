//  MaskStore.swift — the masks' caches (RFC-052 §8.2, §8.3): baked planes, a brush's drawn planes; and the found
//  masks' files (`FoundMaskFiles`), which are not a cache.
//
//  **Planes are caches**: a layer's baked plane under the hash of what it was made from (`MaskBaker.planeKey`), and a
//  brush's drawn plane under the hash of the strokes it holds — a checkpoint every 32 strokes, and the last one drawn,
//  so a new stroke is drawn onto the plane already in memory and Undo redraws from the checkpoint before it (§4.1).
//  Either can always be made again, so this one holds them in memory within `limitBytes` and lets the oldest go.
//
//  **Found masks are the edit's own files** (RFC-052 §8.2, M1c): `FoundMaskFiles`, below. A found mask cannot be made
//  again identically after a system update, so it is kept where the edits are and never under a cache.
//
//  An actor: the baker, the wire and the page all reach it from their own threads.

import CryptoKit
import Foundation
import Metal

actor MaskStore {
    /// What the store keeps in memory, at most: 12 planes of 4096 × 2731 at 16 bits, or 6 drawn brushes at 32.
    let limitBytes: Int
    private var planes: [String: (plane: MaskPlane, used: UInt64)] = [:]
    private struct Drawn { var texture: MTLTexture; var count: Int; var bytes: Int; var checkpoint: Bool; var used: UInt64 }
    private var drawn: [String: Drawn] = [:]
    private var clock: UInt64 = 0

    /// The found masks' files this store reads (`foundPicture`): the app's, unless a check hands its own.
    let files: FoundMaskFiles

    init(limitBytes: Int = 256 << 20, files: FoundMaskFiles = .shared) { self.limitBytes = limitBytes; self.files = files }

    // MARK: baked planes

    func plane(_ key: String) -> MaskPlane? {
        guard let kept = planes[key] else { return nil }
        clock += 1
        planes[key]?.used = clock
        return kept.plane
    }

    func keep(_ plane: MaskPlane) {
        clock += 1
        planes[plane.key] = (plane, clock)
        trim()
    }

    /// Bytes held: planes and drawn brushes.
    var bytes: Int { planes.values.reduce(0) { $0 + $1.plane.bytes } + drawn.values.reduce(0) { $0 + $1.bytes } }
    var planeCount: Int { planes.count }

    func clear() { planes.removeAll(); drawn.removeAll() }

    // MARK: a brush's drawn planes

    /// The key of a brush's first `strokes.count` strokes drawn at this size.
    nonisolated static func drawnKey(_ strokes: [BrushStroke], size: PixelSize, source: PixelSize) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let body = (try? e.encode(strokes)) ?? Data()
        return StampHash.hex(Data("brush|\(size.width)x\(size.height)|\(source.width)x\(source.height)|".utf8) + body)
    }

    /// The longest prefix of `strokes` already drawn: its stroke count and its plane (to be copied, never drawn into).
    func longestDrawn(_ strokes: [BrushStroke], size: PixelSize, source: PixelSize) -> (Int, MTLTexture)? {
        // The newest first: the whole list (a re-bake of the same strokes), then all but the last (a new stroke),
        // then the checkpoints, latest first (Undo).
        var counts = [strokes.count, strokes.count - 1]
        var c = (strokes.count / MaskBaker.checkpointEvery) * MaskBaker.checkpointEvery
        while c > 0 { counts.append(c); c -= MaskBaker.checkpointEvery }
        for n in counts where n > 0 && n <= strokes.count {
            let key = Self.drawnKey(Array(strokes[0..<n]), size: size, source: source)
            if let d = drawn[key] {
                clock += 1
                drawn[key]?.used = clock
                return (d.count, d.texture)
            }
        }
        return nil
    }

    func keepDrawn(_ strokes: [BrushStroke], size: PixelSize, source: PixelSize, texture: MTLTexture, checkpoint: Bool) {
        clock += 1
        drawn[Self.drawnKey(strokes, size: size, source: source)] =
            Drawn(texture: texture, count: strokes.count, bytes: size.width * size.height * 4, checkpoint: checkpoint, used: clock)
        trim()
    }

    // MARK: found masks

    /// A found mask's picture by its asset (`MaskPart.asset`), from the files (`FoundMaskFiles`): the photograph's own
    /// folder first, then any (a Clone Variant's or a pasted layer names an asset its source frame's folder holds).
    /// Nil where there is no file, or the file is not whole (`FoundMaskFiles.read` checks its bytes against its name).
    func foundPicture(_ asset: String, in photograph: UUID? = nil) async -> FoundPicture? {
        try? await files.read(asset, in: photograph)
    }

    // MARK: within the limit

    private func trim() {
        while bytes > limitBytes, planes.count + drawn.count > 1 {
            let oldestPlane = planes.min { $0.value.used < $1.value.used }
            let oldestDrawn = drawn.min { $0.value.used < $1.value.used }
            if let p = oldestPlane, oldestDrawn.map({ p.value.used < $0.value.used }) ?? true { planes[p.key] = nil }
            else if let d = oldestDrawn { drawn[d.key] = nil }
            else { break }
        }
    }
}

// MARK: - the found masks' files

/// **The found masks' files** (RFC-052 §5, §8.2; PRD-E §5.3, §5.4): a 主体, 人 n or 全部人物 picture is found once and
/// kept as a file of the edit, so the same edit shows the same mask on every launch, after a system update, after
/// *Clear Working Copies* and after the caches' tidy — the detector is never asked again unless a person asks
/// (重新查找, which writes a new file and leaves the old one).
///
/// - **Where**: `<library>/Masks/<frame id>/<asset>.spkmask`, beside `library.json` and `layers.json` in
///   `Application Support/<bundle id>/` (`MAC-LIBRARY-DATA.md` §3). **Not** under `WorkingCopies` (anything there may
///   go), `Previews` (rebuildable, out of backups) or Caches. Kept in backups: it is the only copy.
/// - **`<photograph>` is the frame** (`LibraryFrame.ID`), as `layers.json`, the history and every develop are keyed: a
///   variant is a frame of its own with its own layers (MAC-LIBRARY-DATA §2l), and a folder of the file would be
///   shared by variants whose edits are not. A Clone Variant or a pasted layer names an asset that is in its source
///   frame's folder: `read` finds an asset in any folder (it is content-addressed, so any copy is the picture), and
///   `adopt` copies it into the naming frame's own folder (at the page's open and close), so a frame removed later
///   (`remove`, which also hands any file another frame still names to that frame) never takes another's mask.
/// - **Content-addressed and immutable**: the name is the first 128 bits of SHA-256 over the picture's provenance (its
///   `FoundMask` with `invert` cleared: 主体 and 背景 are one file) and its bytes. A file is never written over; `read`
///   recomputes the name from what it reads and refuses a file that does not match it (`damaged`).
/// - **Swept only when nothing names it**: `sweep` takes a frame's files that no edit, no edit-history state and no
///   entry of `layers.json` names, and only those written more than `sweepAge` ago (a find that landed while the page
///   closed). `FoundMaskKeeping` collects the names; when the history cannot be read, nothing is swept.
/// - **A 2.3.x build never touches it**: its launch tidy (`StorageTidy`, `WorkingCopies.sweep`, at 88685135) walks
///   `Previews`, `Previews/Stocks` and `WorkingCopies` only; nothing in it lists the library's root (checked by
///   `git grep` of its `removeItem` and `contentsOfDirectory` calls, 2026-11-13).
///
/// The file: "SPKMASK1", the header's length (UInt32, little-endian), the header (JSON: version, asset, provenance),
/// then the picture's bytes zlib-compressed (8 bits, rows tight, top row first, in S). Written whole beside its place
/// and moved in.
actor FoundMaskFiles {
    /// The app's: the library's folder, set at launch (`AppServices`); nil (a demo, a check that did not ask) reads
    /// and writes nothing, so a found part is missing there, loudly (`MaskBaker.Failure.missingFound`).
    static let shared = FoundMaskFiles(folder: nil)
    static let folderName = "Masks"
    static let fileExtension = "spkmask"
    /// A file younger than this is never swept: a find that was being kept as the page closed.
    static let sweepAge: TimeInterval = 120
    private static let magic = Array("SPKMASK1".utf8)

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// No library folder (a demo library, or one that keeps nothing on disk).
        case noFolder
        case notWritten(String)
        /// A file that is not whole or not what its name says.
        case damaged(String)
        var description: String {
            switch self {
            case .noFolder: "the found masks have no folder (a library that keeps nothing on disk)"
            case .notWritten(let s): "the found mask was not written: \(s)"
            case .damaged(let s): "the found mask's file is damaged: \(s)"
            }
        }
    }

    /// Where the files are: set once by the app at launch, before anything develops — so held apart from the actor
    /// (`use` is synchronous), behind a lock.
    private final class Place: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        init(_ url: URL?) { self.url = url }
        var value: URL? {
            get { lock.lock(); defer { lock.unlock() }; return url }
            set { lock.lock(); url = newValue; lock.unlock() }
        }
    }
    private let place: Place
    var folder: URL? { place.value }
    private let files = FileManager.default

    init(folder: URL?) { place = Place(folder) }

    /// The library's `Masks` folder, for the app's library at `root` (`ImportService.root`).
    nonisolated static func folder(in root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    /// Where the files are from now on (the app, once, at launch; a check, for its own folder).
    nonisolated func use(_ folder: URL?) { place.value = folder }

    // MARK: names

    /// What is hashed besides the bytes: the provenance, `invert` cleared (the part's, not the picture's).
    nonisolated static func provenance(_ mask: FoundMask) -> FoundMask {
        var m = mask
        m.invert = false
        return m
    }

    /// The asset's name: 32 hex digits of SHA-256 over "spkmask v1|", the provenance as sorted JSON, "|", the bytes.
    nonisolated static func asset(_ picture: FoundPicture, _ mask: FoundMask) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var h = SHA256()
        h.update(data: Data("spkmask v1|".utf8))
        h.update(data: (try? e.encode(provenance(mask))) ?? Data())
        h.update(data: Data("|\(picture.width)x\(picture.height)|".utf8))
        picture.bytes.withUnsafeBytes { h.update(bufferPointer: $0) }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// An asset's name as this build writes one: anything else (a path, "..") names no file.
    nonisolated static func isAsset(_ s: String) -> Bool {
        s.count == 32 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    nonisolated static func fileName(_ asset: String) -> String { asset + "." + fileExtension }

    // MARK: the file's bytes

    private struct Header: Codable {
        enum CodingKeys: String, CodingKey { case version = "version", asset = "asset", mask = "mask" }
        var version = 1
        var asset: String
        var mask: FoundMask
    }

    /// The file's bytes for a picture and its provenance; nil where it does not compress (never seen).
    nonisolated static func encode(_ picture: FoundPicture, _ mask: FoundMask) -> (asset: String, data: Data)? {
        let asset = asset(picture, mask)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard picture.bytes.count == picture.width * picture.height,
              let header = try? e.encode(Header(asset: asset, mask: provenance(mask))),
              let packed = try? (Data(picture.bytes) as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data(magic)
        withUnsafeBytes(of: UInt32(header.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(packed)
        return (asset, out)
    }

    /// A file's picture and provenance, checked against its name: nil where it is not whole, or its bytes and
    /// provenance do not hash to the name it carries.
    nonisolated static func decode(_ data: Data) -> (asset: String, mask: FoundMask, picture: FoundPicture)? {
        guard data.count > 12, Array(data.prefix(8)) == magic else { return nil }
        let length = data.subdata(in: 8..<12).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, data.count > 12 + length,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length))),
              header.mask.width > 0, header.mask.height > 0,
              let bytes = try? (data.subdata(in: (12 + length)..<data.count) as NSData).decompressed(using: .zlib) as Data,
              bytes.count == header.mask.width * header.mask.height else { return nil }
        let picture = FoundPicture(width: header.mask.width, height: header.mask.height, bytes: [UInt8](bytes))
        guard asset(picture, header.mask) == header.asset else { return nil }
        return (header.asset, header.mask, picture)
    }

    // MARK: write and read

    private func own(_ frame: UUID) -> URL? { folder?.appendingPathComponent(frame.uuidString, isDirectory: true) }

    /// Where `asset` is: the frame's own folder first, then any frame's. Nil where no folder holds it.
    func url(_ asset: String, in frame: UUID? = nil) -> URL? {
        guard Self.isAsset(asset), let folder else { return nil }
        let name = Self.fileName(asset)
        if let frame, let own = own(frame)?.appendingPathComponent(name), files.fileExists(atPath: own.path) { return own }
        for sub in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where UUID(uuidString: sub.lastPathComponent) != nil {
            let f = sub.appendingPathComponent(name)
            if files.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// The picture, kept as the frame's file: its asset (the name the part keeps). A file already there by that name
    /// is the same picture (content-addressed) and is left as it is; one that is not whole is replaced.
    func write(_ picture: FoundPicture, _ mask: FoundMask, frame: UUID) throws -> String {
        guard let place = own(frame) else { throw Failure.noFolder }
        guard let (asset, data) = Self.encode(picture, mask) else { throw Failure.notWritten("\(picture.width) x \(picture.height): not a picture") }
        let target = place.appendingPathComponent(Self.fileName(asset))
        if let kept = try? Data(contentsOf: target), Self.decode(kept)?.asset == asset { return asset }
        do {
            try files.createDirectory(at: place, withIntermediateDirectories: true)
            let partial = place.appendingPathComponent(".partial-" + UUID().uuidString)
            try data.write(to: partial)
            _ = try? files.removeItem(at: target)
            try files.moveItem(at: partial, to: target)
        } catch { throw Failure.notWritten("\(error)") }
        return asset
    }

    /// The picture named `asset`, from wherever it is (`url`): nil where no folder holds it; `damaged` where the file
    /// is there and is not that picture.
    func read(_ asset: String, in frame: UUID? = nil) throws -> FoundPicture? {
        guard let url = url(asset, in: frame) else { return nil }
        guard let data = try? Data(contentsOf: url), let made = Self.decode(data), made.asset == asset else {
            throw Failure.damaged(url.lastPathComponent)
        }
        return made.picture
    }

    /// The provenance kept with `asset` (what the detector was, on which system, from which source).
    func provenance(of asset: String) -> FoundMask? {
        guard let url = url(asset), let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(data)?.mask
    }

    /// Of `assets`, the ones no folder holds whole: what a page marks (`FoundMaskKeeping.missing`).
    func missing(_ assets: Set<String>) -> Set<String> {
        assets.filter { a in (try? read(a)) == nil }
    }

    // MARK: keeping and sweeping

    /// The assets `frame` names and does not hold in its own folder, copied there from another frame's (a clone's, a
    /// paste's): from then on the frame's mask does not depend on the other frame staying. How many were copied.
    @discardableResult
    func adopt(_ assets: Set<String>, into frame: UUID) -> Int {
        guard let place = own(frame) else { return 0 }
        var made = 0
        for asset in assets where Self.isAsset(asset) {
            let target = place.appendingPathComponent(Self.fileName(asset))
            guard !files.fileExists(atPath: target.path), let from = url(asset) else { continue }
            try? files.createDirectory(at: place, withIntermediateDirectories: true)
            if (try? files.copyItem(at: from, to: target)) != nil { made += 1 }
        }
        return made
    }

    /// The frame's files that `keeping` does not name and that were written `age` seconds ago or more, removed (the
    /// page closed, RFC-052 §8.2). `keeping` is every name an edit, a history state or `layers.json` holds
    /// (`FoundMaskKeeping.names`). The assets removed.
    @discardableResult
    func sweep(frame: UUID, keeping: Set<String>, now: Date = Date(), age: TimeInterval = FoundMaskFiles.sweepAge) -> [String] {
        guard let place = own(frame) else { return [] }
        var gone: [String] = []
        for file in (try? files.contentsOfDirectory(at: place, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = file.lastPathComponent
            if name.hasPrefix(".partial-") {
                // A write the app was ended in the middle of.
                if let d = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   now.timeIntervalSince(d) >= age { try? files.removeItem(at: file) }
                continue
            }
            guard file.pathExtension == Self.fileExtension else { continue }
            let asset = file.deletingPathExtension().lastPathComponent
            guard Self.isAsset(asset), !keeping.contains(asset),
                  let d = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(d) >= age, (try? files.removeItem(at: file)) != nil else { continue }
            gone.append(asset)
        }
        if (try? files.contentsOfDirectory(atPath: place.path))?.isEmpty == true { try? files.removeItem(at: place) }
        return gone
    }

    /// A frame removed from the library takes its folder, but a file another frame names (`others`: each remaining
    /// frame's names) is moved to the first such frame's folder first. (handed, removed).
    @discardableResult
    func remove(frame: UUID, handing others: [UUID: Set<String>]) -> (handed: Int, removed: Int) {
        guard let place = own(frame), files.fileExists(atPath: place.path) else { return (0, 0) }
        var handed = 0, removed = 0
        for file in (try? files.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == Self.fileExtension {
            let asset = file.deletingPathExtension().lastPathComponent
            if let heir = others.filter({ $0.key != frame && $0.value.contains(asset) }).keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
               let to = own(heir)?.appendingPathComponent(file.lastPathComponent) {
                try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if files.fileExists(atPath: to.path) || (try? files.moveItem(at: file, to: to)) != nil { handed += 1; continue }
            }
            removed += 1
        }
        try? files.removeItem(at: place)
        return (handed, removed)
    }

    /// At launch: the folder of every frame the library no longer has goes (`remove`, handing what another names) —
    /// a frame removed while the app was ended between the library's write and its files'. `frames`: every frame of
    /// the library with its names. Never a file of a frame that is there.
    @discardableResult
    func tidy(frames: [UUID: Set<String>]) -> (handed: Int, removed: Int) {
        guard let folder else { return (0, 0) }
        var handed = 0, removed = 0
        for sub in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: sub.lastPathComponent), frames[id] == nil else { continue }
            let r = remove(frame: id, handing: frames)
            handed += r.handed; removed += r.removed
        }
        return (handed, removed)
    }

    /// What the files take on disk.
    func bytes() -> Int64 {
        guard let folder, let walk = files.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in walk { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}
