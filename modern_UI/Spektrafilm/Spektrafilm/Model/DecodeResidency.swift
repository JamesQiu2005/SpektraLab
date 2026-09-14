import Foundation

/// The identity of a decoded frame. White-balance settings are part of the
/// key, because changing them changes the pixels.
struct DecodeKey: Hashable, Sendable {
    let url: URL
    let settings: DecodeSettings
}

/// A one-shot handoff for work that may be queued behind another job. The
/// closure can retain this object after cancellation, but `release()` drops
/// the image before the queued closure runs.
final class DecodeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var image: DecodedImage?

    init(_ image: DecodedImage) {
        self.image = image
    }

    func take() -> DecodedImage? {
        lock.withLock {
            defer { image = nil }
            return image
        }
    }

    func release() {
        lock.withLock { image = nil }
    }
}

/// The decoded frame's sole owner. Capacity is one: Q3 measured more than
/// 1.5 GB retained per 24 MP decode, so a previous frame is not kept.
@MainActor
final class DecodeResidency {
    static let capacity = 1
    /// Q3 measured roughly 90 bytes per pixel retained across the two decode
    /// images and Core Image's working storage on this machine.
    static let estimatedBytesPerPixel = 90

    private struct Entry {
        let key: DecodeKey
        let image: DecodedImage
        let handle: MemoryArena.Handle
    }

    private let arena: MemoryArena
    private var entry: Entry?

    init(arena: MemoryArena) {
        self.arena = arena
    }

    var image: DecodedImage? { entry?.image }
    var key: DecodeKey? { entry?.key }
    var accountedBytes: Int {
        guard let image else { return 0 }
        return Self.estimatedBytes(for: image)
    }

    func contains(_ key: DecodeKey) -> Bool {
        entry?.key == key
    }

    /// Adopt a newly decoded image and release the one it replaces.
    @discardableResult
    func adopt(_ image: DecodedImage, for key: DecodeKey) -> DecodeLease {
        clear()
        let handle = arena.registerPinned(bytes: Self.estimatedBytes(for: image),
                                          kind: "decode")
        entry = Entry(key: key, image: image, handle: handle)
        return DecodeLease(image)
    }

    func lease(for key: DecodeKey) -> DecodeLease? {
        guard let entry, entry.key == key else { return nil }
        return DecodeLease(entry.image)
    }

    func clear() {
        guard let entry else { return }
        arena.release(entry.handle)
        self.entry = nil
    }

    private static func estimatedBytes(for image: DecodedImage) -> Int {
        let pixels = Double(image.pixelSize.width) * Double(image.pixelSize.height)
        return Int((pixels * Double(estimatedBytesPerPixel)).rounded(.up))
    }
}
