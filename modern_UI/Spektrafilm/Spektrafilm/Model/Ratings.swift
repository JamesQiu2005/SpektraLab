//  Ratings.swift — a star rating (0–5) per photograph, Lightroom-style.
//
//  Kept apart from the sidecar on purpose. A sidecar is "this frame has been
//  developed": the filmstrip's edited mark reads its existence, and a rating
//  is a culling decision made before any development. Writing a rating into
//  the sidecar would make every rated-but-untouched frame look edited.
//
//  One small JSON file beside the sidecar store,
//  `~/Library/Application Support/SpektraLab/Ratings.json`, keyed by the
//  same key the sidecar uses (`Sidecar.key(for:)`: file name + path hash), so
//  a rating follows exactly the frames a sidecar would. Nothing is written
//  next to the user's photographs.
//
//  Main-actor only: every reader is UI, and the file is a few KB. A write is
//  synchronous and atomic; `didChange` lets the filmstrip and the import
//  culler redraw without either owning the store.

import Foundation

@MainActor
enum Ratings {
    /// Posted after a rating changes; `object` is the image URL.
    static let didChange = Notification.Name("SpektraLab.Ratings.didChange")

    static let range = 0...5

    /// The file, under the sidecar store's parent (tests get their own
    /// directory because `Sidecar.storeDirectory` is redirected under XCTest).
    static var fileURL: URL {
        Sidecar.storeDirectory.deletingLastPathComponent().appending(path: "Ratings.json")
    }

    private static var cache: [String: Int]?
    private static var cacheURL: URL?

    private static func table() -> [String: Int] {
        let url = fileURL
        if let cache, cacheURL == url { return cache }
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        cache = loaded
        cacheURL = url
        return loaded
    }

    /// 0 when the frame was never rated.
    static func rating(for image: URL) -> Int {
        table()[Sidecar.key(for: image)] ?? 0
    }

    /// Set (0 clears). Out-of-range values are clamped.
    static func set(_ stars: Int, for image: URL) {
        let stars = min(max(stars, range.lowerBound), range.upperBound)
        var t = table()
        let key = Sidecar.key(for: image)
        guard (t[key] ?? 0) != stars else { return }
        if stars == 0 { t.removeValue(forKey: key) } else { t[key] = stars }
        cache = t
        cacheURL = fileURL
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: didChange, object: image)
    }

    /// Forget the in-memory copy (tests, or after the store moves).
    static func reload() {
        cache = nil
        cacheURL = nil
    }
}
