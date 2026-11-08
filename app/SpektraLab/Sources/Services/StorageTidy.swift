//  StorageTidy.swift — the app's own folders, held to the library.
//
//  What the app writes under `Previews` belongs to a frame: its preview copy
//  (`<an id>.jpg`), its kept develop (`dev-<frame>-<stamp>`), a pair's guide
//  (`pair-<pair>-…`). A frame that leaves the library takes its files with it
//  (`AppServices.remove`); this is for what is left when that did not happen — a
//  build before 2026-10-10 left every removed frame's kept develop behind, the
//  first run's page empties the library and leaves its files, the app can be
//  ended between a frame going and its files going. At launch, the files no
//  frame names go.
//
//  Foundation only: `tools/storage_selftest.swift` holds it to its rules on
//  this Mac.

import Foundation

enum StorageTidy {
    /// Whether a file's name is one the app gives a file under `Previews`.
    /// Anything else there is not the app's make and is left alone.
    static func isAppMade(_ name: String) -> Bool {
        if name.hasPrefix("dev-") || name.hasPrefix("pair-") { return true }
        let ns = name as NSString
        return ns.pathExtension == "jpg" && UUID(uuidString: ns.deletingPathExtension) != nil
    }

    /// The files in `folder` that are the app's make and that the library
    /// does not name go. `keeping` is the name of every file the library's
    /// frames name, as the library was read — names, not paths: every file
    /// there has a name of its own, and a path can be spelt two ways. Only a
    /// file `age` seconds old or more: one written since may be a develop the
    /// library has not been told of yet. Returns what went.
    @discardableResult
    static func sweep(_ folder: URL, keeping: Set<String>, now: Date = Date(), age: TimeInterval = 3600) -> (files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for file in all where isAppMade(file.lastPathComponent) && !keeping.contains(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let written = values.contentModificationDate, now.timeIntervalSince(written) >= age,
                  (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    /// A file as a word in a develop's stamp: its place under `root` where it
    /// is there, the whole path where it is not. The app's folder moves with
    /// an install of the app (`LibraryPersistence` keeps a picture's path from
    /// it for the same reason), and a stamp with the whole path in it was
    /// another stamp after every install.
    static func stampWord(_ url: URL, under root: URL) -> String {
        let root = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}

//  Develop's strips (`StockPreviews`): each card a file beside the frame's
//  previews, `Previews/Stocks/<frame>/<source>-<key>.jpg` — `source` eight hex
//  of what the frame's pixels are read from (the file, its size, a RAW's
//  decode), `key` the card's sixteen (`StockPreviewKey`). Made again whenever
//  they are wanted and missing, so every rule here may take one:
//
//  - **a frame's cards go with it** (`AppServices.remove`), and at launch the
//    folder of any frame the library no longer has goes whole;
//  - **a frame's cards of another source go** when one of its new source is
//    written: another file, size or decode is another picture;
//  - **they share the previews' space** (`holdCards(sharing:)`, the owner,
//    2026-10-17: "They share the same cache space and are all budgeted by the
//    same cache space cap, with the priority on actual image render instead of
//    the preview ones"): Storage's *Preview copies up to* is for everything
//    under `Previews`, and past it cards go, the card shown longest ago first —
//    a card's file is dated when it was last shown — never one of the frame on
//    the page, and **never a render for a card**: a preview copy, a kept
//    develop or a pair's guide is not taken by this;
//  - nothing that is not a card's name, or not in a frame's folder, is touched.
extension StorageTidy {
    /// Their own limit until 2026-10-17: 32 MB, about a thousand cards (a card is
    /// 20-40 KB, 336 × 252, JPEG at 0.9) — fewer than 25 film changes of a
    /// whole library since a film brings its paper (both strips move). The
    /// default where no shared limit is given (a check on this Mac).
    static let cardsLimit: Int64 = 32 << 20

    static func cardsFolder(in previews: URL) -> URL { previews.appendingPathComponent("Stocks", isDirectory: true) }

    static func cardFile(frame: UUID, source: String, key: String, in folder: URL) -> URL {
        folder.appendingPathComponent(frame.uuidString, isDirectory: true).appendingPathComponent("\(source)-\(key).jpg")
    }

    /// `<8 hex>-<16 hex>.jpg`, and nothing else.
    static func isCard(_ name: String) -> Bool {
        let ns = name as NSString
        guard ns.pathExtension == "jpg" else { return false }
        let parts = ns.deletingPathExtension.split(separator: "-", omittingEmptySubsequences: false)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return parts.count == 2 && parts[0].count == 8 && parts[1].count == 16
            && parts.allSatisfy { $0.unicodeScalars.allSatisfy(hex.contains) }
    }

    /// A frame's folder of cards, by its name; nil for anything else.
    private static func cardFrame(_ folder: URL) -> UUID? {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return UUID(uuidString: folder.lastPathComponent)
    }

    private static func cards(in frameFolder: URL) -> [(url: URL, bytes: Int64, shown: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: frameFolder, includingPropertiesForKeys: keys)) ?? []).compactMap { url in
            guard isCard(url.lastPathComponent), let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
    }

    private static func frameFolders(_ folder: URL) -> [(url: URL, frame: UUID)] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .compactMap { url in cardFrame(url).map { (url, $0) } }
    }

    /// At launch: the cards of every frame the library no longer has go, with
    /// their folder. Returns what went.
    @discardableResult
    static func sweepCards(_ folder: URL, keepingFrames frames: Set<UUID>) -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        for (url, frame) in frameFolders(folder) where !frames.contains(frame) {
            let mine = cards(in: url)
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            files += mine.count
            bytes += mine.reduce(0) { $0 + $1.bytes }
        }
        return (files, bytes)
    }

    /// A frame's cards go: it has left the library.
    static func discardCards(of frames: [UUID], in folder: URL) {
        for frame in frames {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(frame.uuidString, isDirectory: true))
        }
    }

    /// The frame's cards read from another source than `source` go.
    @discardableResult
    static func dropCards(of frame: UUID, otherThan source: String, in folder: URL) -> Int {
        var went = 0
        for card in cards(in: folder.appendingPathComponent(frame.uuidString, isDirectory: true))
        where !card.url.lastPathComponent.hasPrefix(source + "-") {
            if (try? FileManager.default.removeItem(at: card.url)) != nil { went += 1 }
        }
        return went
    }

    /// Every card held to `limit` bytes: the one shown longest ago goes first,
    /// and none of `sparing`'s (the frame on the page). Returns what went.
    @discardableResult
    static func holdCards(_ folder: URL, to limit: Int64 = cardsLimit, sparing: UUID? = nil) -> (files: Int, bytes: Int64) {
        var all: [(url: URL, bytes: Int64, shown: Date, frame: UUID)] = []
        for (url, frame) in frameFolders(folder) {
            all += cards(in: url).map { ($0.url, $0.bytes, $0.shown, frame) }
        }
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        var files = 0, bytes: Int64 = 0
        for card in all.sorted(by: { $0.shown < $1.shown }) where card.frame != sparing {
            guard total > limit else { break }
            guard (try? FileManager.default.removeItem(at: card.url)) != nil else { continue }
            total -= card.bytes
            files += 1
            bytes += card.bytes
        }
        return (files, bytes)
    }

    /// What the renders under `previews` take: every file directly in it — the
    /// preview copies, the kept develops, the pairs' guides — and not the cards'
    /// folder.
    static func renderBytes(in previews: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(at: previews, includingPropertiesForKeys: keys)) ?? [])
            .reduce(Int64(0)) { sum, url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return sum }
                return sum + Int64(v.fileSize ?? 0)
            }
    }

    /// The cards held to what the renders leave of `limit`, the space all of
    /// `previews` shares: renders first, so where they take it all, every card
    /// but the page's goes and no render does. Returns what went.
    @discardableResult
    static func holdCards(sharing previews: URL, limit: Int64, sparing: UUID? = nil) -> (files: Int, bytes: Int64) {
        holdCards(cardsFolder(in: previews), to: max(0, limit - renderBytes(in: previews)), sparing: sparing)
    }
}
