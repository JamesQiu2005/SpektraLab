//  ThumbnailCache.swift — filmstrip thumbnails from ImageIO's embedded
//  preview, never from the engine, generated off the main actor.

import AppKit
import ImageIO

private struct ThumbnailKey: Hashable, Sendable {
    let url: URL
    let maxPixel: Int
}

/// Lock-protected storage, separate from the asynchronous work scheduler so
/// an arena eviction can drop its reference synchronously from the callback.
private final class ThumbnailStorage: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        var handle: MemoryArena.Handle?
    }

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var value: CacheValue
        let slot: Slot
    }

    private let lock = NSRecursiveLock()
    private let arena: MemoryArena
    private let byteLimit: Int
    private var entries: [ThumbnailKey: Entry] = [:]
    /// A rendered thumbnail replaces every embedded-preview size for that URL,
    /// which is the behavior the old URL-only cache had.
    private var processed: [URL: ThumbnailKey] = [:]
    private var total = 0
    private var clock = 0.0

    init(arena: MemoryArena, byteLimit: Int) {
        self.arena = arena
        self.byteLimit = max(0, byteLimit)
    }

    func image(for key: ThumbnailKey) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let lookup = processed[key.url] ?? key
        guard var entry = entries[lookup] else { return nil }
        entry.value.hit(at: Date().timeIntervalSinceReferenceDate)
        entries[lookup] = entry
        if let handle = entry.slot.handle { arena.touch(handle) }
        return entry.image
    }

    @discardableResult
    func put(_ image: CGImage, key: ThumbnailKey, costMs: Double,
             replacingURL: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !replacingURL, processed[key.url] != nil { return true }
        if replacingURL {
            let old = entries.keys.filter { $0.url == key.url }
            for oldKey in old { removeLocked(oldKey, releaseArena: true) }
            processed[key.url] = nil
        } else {
            removeLocked(key, releaseArena: true)
        }

        let bytes = max(1, image.bytesPerRow * image.height)
        let slot = Slot()
        let admitted = arena.admitCache(bytes: bytes, kind: "thumbnails", costMs: costMs,
                                        evict: { [weak self] in
                                            self?.drop(key, matching: slot)
                                        })
        guard let admitted else { return false }
        slot.handle = admitted
        entries[key] = Entry(image: image, bytes: bytes,
                             value: CacheValue(costMs: costMs, bytes: bytes,
                                               lastUsed: Date().timeIntervalSinceReferenceDate),
                             slot: slot)
        total += bytes
        if replacingURL { processed[key.url] = key }
        trimLocked()
        return true
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries.values {
            if let handle = entry.slot.handle { arena.release(handle) }
        }
        entries.removeAll()
        processed.removeAll()
        total = 0
        clock = 0
    }

    var count: Int { lock.withLock { entries.count } }
    var bytes: Int { lock.withLock { total } }

    private func drop(_ key: ThumbnailKey, matching slot: Slot) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[key]?.slot === slot else { return }
        removeLocked(key, releaseArena: false)
    }

    private func trimLocked() {
        while total > byteLimit {
            guard let key = entries.min(by: {
                let lp = $0.value.value.priority(clock: clock)
                let rp = $1.value.value.priority(clock: clock)
                return lp == rp ? $0.value.value.lastUsed < $1.value.value.lastUsed : lp < rp
            })?.key else { break }
            clock = max(clock, entries[key]!.value.priority(clock: clock))
            removeLocked(key, releaseArena: true)
        }
    }

    private func removeLocked(_ key: ThumbnailKey, releaseArena: Bool) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if releaseArena, let handle = entry.slot.handle { arena.release(handle) }
        total -= entry.bytes
        if processed[key.url] == key { processed[key.url] = nil }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    typealias Decoder = @Sendable (URL, Int) async -> CGImage?

    private struct Decoded: Sendable {
        let image: CGImage
        let costMs: Double
    }

    static let shared = ThumbnailCache(arena: .shared)

    private let storage: ThumbnailStorage
    private let decode: Decoder
    private let lock = NSLock()
    private var inFlight: [ThumbnailKey: Task<Decoded?, Never>] = [:]
    private var generation = 0
    private var revision: [URL: Int] = [:]

    init(arena: MemoryArena = MemoryArena(),
         byteLimit: Int = 256_000_000,
         decoder: @escaping Decoder = ThumbnailCache.decodeEmbedded) {
        storage = ThumbnailStorage(arena: arena, byteLimit: byteLimit)
        decode = decoder
    }

    func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
        let key = ThumbnailKey(url: url, maxPixel: max(1, maxPixel))
        if let cached = storage.image(for: key) { return cached }

        let request: (task: Task<Decoded?, Never>, generation: Int, revision: Int) =
            lock.withLock {
                if let task = inFlight[key] {
                    return (task, generation, revision[url] ?? 0)
                }
                let generation = generation
                let revision = revision[url] ?? 0
                let decode = decode
                let task = Task<Decoded?, Never>.detached(priority: .utility) {
                    guard !Task.isCancelled else { return nil }
                    let start = Date()
                    guard let image = await decode(url, key.maxPixel) else { return nil }
                    return Decoded(image: image,
                                   costMs: Date().timeIntervalSince(start) * 1000)
                }
                inFlight[key] = task
                return (task, generation, revision)
            }

        let decoded = await request.task.value
        let accepted = lock.withLock {
            guard generation == request.generation,
                  (revision[url] ?? 0) == request.revision else { return false }
            inFlight[key] = nil
            return true
        }
        guard accepted else { return nil }
        guard let decoded else { return nil }
        storage.put(decoded.image, key: key, costMs: decoded.costMs,
                    replacingURL: false)
        return decoded.image
    }

    /// Replace the embedded preview with a rendered one. The rendered size is
    /// the key's size, and the replacement wins for every requested size for
    /// that URL until it is evicted.
    func store(_ image: CGImage, for url: URL) {
        let stale = lock.withLock {
            revision[url, default: 0] += 1
            let keys = inFlight.keys.filter { $0.url == url }
            let tasks = keys.compactMap { inFlight.removeValue(forKey: $0) }
            return tasks
        }
        stale.forEach { $0.cancel() }
        let key = ThumbnailKey(url: url, maxPixel: max(1, image.width, image.height))
        storage.put(image, key: key, costMs: 0, replacingURL: true)
    }

    /// A new folder is a new generation. Detached work from the old one may
    /// finish, but it cannot repopulate the cache or replace a newer result.
    func clear() {
        let stale = lock.withLock {
            generation &+= 1
            revision.removeAll()
            let tasks = Array(inFlight.values)
            inFlight.removeAll()
            return tasks
        }
        stale.forEach { $0.cancel() }
        storage.removeAll()
    }

    var cachedCount: Int { storage.count }
    var cachedBytes: Int { storage.bytes }

    private static func decodeEmbedded(_ url: URL, _ maxPixel: Int) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
