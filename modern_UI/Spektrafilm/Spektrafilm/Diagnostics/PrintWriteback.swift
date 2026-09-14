import Foundation
import Metal

struct StagedPrint: @unchecked Sendable {
    let key: CacheKey
    let texture: MTLTexture
    let sourceWidth: Int
    let sourceHeight: Int
    let costMs: Double

    var bytes: Int { texture.width * texture.height * 8 }
}

/// A bounded FIFO between finished print textures and the disk index.
///
/// It deliberately drops the oldest entry when staging exceeds one full-size
/// print. An entry that is dropped was never promised to the user; the next
/// visit recomputes it.
actor PrintWriteback {
    private let store: DiskCacheStore
    private let maxStagedBytes: Int
    private var queue: [StagedPrint] = []
    private var stagedBytes = 0
    private var draining = false
    private(set) var droppedCount = 0

    init(store: DiskCacheStore, maxStagedBytes: Int = 500_000_000) {
        self.store = store
        self.maxStagedBytes = maxStagedBytes
    }

    func enqueue(_ entry: StagedPrint) {
        queue.append(entry)
        stagedBytes += entry.bytes
        while stagedBytes > maxStagedBytes, !queue.isEmpty {
            let dropped = queue.removeFirst()
            stagedBytes -= dropped.bytes
            droppedCount += 1
        }
    }

    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            stagedBytes -= entry.bytes
            try? await store.store(
                key: entry.key,
                data: entry.texture.rgba16Bytes(),
                width: entry.texture.width,
                height: entry.texture.height,
                sourceWidth: entry.sourceWidth,
                sourceHeight: entry.sourceHeight,
                format: "rgba16Unorm",
                costMs: entry.costMs
            )
        }
    }

    var isEmpty: Bool { queue.isEmpty }
    var queuedBytes: Int { stagedBytes }
    var queuedCount: Int { queue.count }
}
