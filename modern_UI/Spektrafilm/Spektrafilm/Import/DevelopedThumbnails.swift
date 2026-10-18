//  DevelopedThumbnails.swift — the picture of a developed frame, on disk, so
//  it outlives the RAM cache that shows it.
//
//  `ThumbnailCache` shows a frame as the camera's embedded preview until the
//  frame is developed, and as a picture of its print after. That second
//  picture lived in RAM only: every `open(urls:)` emptied the cache, eviction
//  took it first (it was admitted at zero cost), and a relaunch started
//  without it. Each time, the strip went back to the camera's preview — the
//  frame without its adjustments. The sidecar still held every setting, but
//  to the person the edit was gone (a 1.3.3 report).
//
//  So the picture is kept here as well: 320 px JPEGs of tens of KB, in the
//  caches folder, bounded at launch. It is never the record of an edit, only
//  a faster way to show one — it is shown for a frame whose sidecar says it
//  was developed, and only while the file is the one it was made from. When
//  it is missing the strip shows the camera's preview, and the canvas, which
//  develops such a frame again from its sidecar (`Session.load`), writes it
//  back.

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DevelopedThumbnails {
    /// `~/Library/Caches/com.hanze.spektralab/developed-thumbnails/`.
    static var directory: URL { override.value ?? defaultDirectory }

    static let defaultDirectory = Session.cacheRoot.appending(path: "developed-thumbnails")

    /// Under XCTest a folder of the run's own, for the reason
    /// `Sidecar.storeOverride` gives: the suite's fixtures are fresh copies
    /// every run, and their pictures would pile up in the user's caches.
    private static let override = Guarded<URL?>(
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? nil
            : FileManager.default.temporaryDirectory
                .appending(path: "spektralab-test-thumbnails-\(ProcessInfo.processInfo.processIdentifier)"))

    /// Point the store somewhere else. For tests.
    static func useDirectory(_ url: URL?) { override.value = url }

    /// The frame's name in the sidecar store, then a digest of the file's
    /// identity (volume, file id, size, modification date). The first makes
    /// one frame one name in both stores; the second makes a different file
    /// at the same path a miss rather than another photograph's picture.
    static func url(for image: URL) -> URL {
        // A fresh URL, because a `URL` caches the resource values it has read:
        // asked through the frame's own long-lived URL, a file replaced at
        // that path kept the old file's size and date, and matched.
        let fresh = URL(fileURLWithPath: image.path)
        let identity = SHA256.hash(data: Data(CacheKey.sourceIdentity(for: fresh).utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(stem(for: image))-\(identity).jpg")
    }

    private static func stem(for image: URL) -> String {
        String(Sidecar.key(for: image).dropLast(".spektra.json".count))
    }

    /// Whether the frame's sidecar says it has been developed.
    ///
    /// Read, not `Sidecar.load`: that one may re-key or migrate a sidecar,
    /// which is a write, and this runs off the main actor for every
    /// thumbnail the strip asks for. `Session.open(urls:)` has already done
    /// any migrating for the frames on screen.
    static func isDeveloped(_ image: URL) -> Bool {
        guard let data = try? Data(contentsOf: Sidecar.url(for: image)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return false }
        return sidecar.state != .unprocessed
    }

    /// The developed picture of `image`, or nil if it was never developed,
    /// was reset since, or is not the file the picture was made from.
    static func image(for image: URL) -> CGImage? {
        guard isDeveloped(image) else { return nil }
        let file = url(for: image)
        // Asked first, because ImageIO logs an error for every missing file
        // and a miss here is ordinary: a frame developed before this store
        // existed, or one whose picture the launch trim let go.
        guard FileManager.default.fileExists(atPath: file.path),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        // Used, so the launch trim keeps it over pictures nobody has looked at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return picture
    }

    /// Write the picture. Quiet on failure: the strip falls back to the
    /// camera's preview, and the frame's settings are untouched either way.
    static func store(_ picture: CGImage, for image: URL) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, picture,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (data as Data).write(to: url(for: image), options: .atomic)
    }

    /// Remove every picture of the frame, whichever file it was made from. A
    /// reset frame is the camera's picture again.
    static func remove(for image: URL) {
        let prefix = stem(for: image) + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Keep the folder under `limit`, least recently used first. At launch,
    /// off the main actor. 256 MB is roughly ten thousand frames.
    static func trim(toBytes limit: Int = 256_000_000) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [(url: URL, used: Date, bytes: Int)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }
}

/// A developed frame's thumbnail, handed across isolation domains. A
/// `CGImage` is immutable once made.
struct DevelopedPicture: @unchecked Sendable {
    let image: CGImage
}

/// Coalesces the pictures a frame produces while it is being edited.
///
/// A print lands for every slider step, and each one makes a new thumbnail;
/// writing every one of them would be dozens of files a second during a drag.
/// The latest picture per frame is written once the frames have been quiet
/// for `delay`. One actor, so a reset's `remove` is ordered against a write
/// already pending for the same frame.
actor DevelopedThumbnailWriter {
    static let shared = DevelopedThumbnailWriter()

    private var pending: [URL: DevelopedPicture] = [:]
    private var task: Task<Void, Never>?
    let delay: Duration

    init(delay: Duration = .milliseconds(750)) { self.delay = delay }

    nonisolated func submit(_ picture: CGImage, for image: URL) {
        let box = DevelopedPicture(image: picture)
        Task { await self.enqueue(box, for: image) }
    }

    /// Drop anything pending for the frame and delete its pictures on disk.
    nonisolated func remove(_ image: URL) {
        Task { await self.forget(image) }
    }

    /// Write everything pending now. For tests, and for anything that must
    /// find the picture on disk before the writer would have got to it.
    func flush() {
        task?.cancel()
        writeAll()
    }

    private func enqueue(_ box: DevelopedPicture, for image: URL) {
        pending[image] = box
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.writeAll()
        }
    }

    private func forget(_ image: URL) {
        pending[image] = nil
        DevelopedThumbnails.remove(for: image)
    }

    private func writeAll() {
        let batch = pending
        pending.removeAll()
        for (image, box) in batch { DevelopedThumbnails.store(box.image, for: image) }
    }
}
