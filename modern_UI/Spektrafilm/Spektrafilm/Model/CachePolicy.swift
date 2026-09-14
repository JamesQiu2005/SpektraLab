import Foundation

enum CacheKind: String, Codable, Hashable, Sendable {
    case decode
    case source
    case printLive = "print_live"
    case printFull = "print_full"
}

enum CacheTier: String, Codable, Hashable, Sendable {
    case live
    case full
}

/// One key for the RAM heap and the disk index. `sourceIdentity` is the
/// inode/volume/size/mtime identity; `configuration` is the encoded decode or
/// print configuration that changes pixels.
struct CacheKey: Codable, Hashable, Sendable {
    static let formatVersion = 1

    let version: Int
    let kind: CacheKind
    let sourceIdentity: String
    let configuration: String
    let tier: CacheTier?
    let previewLongEdge: Int?
    let engineVersion: String

    init(kind: CacheKind, sourceIdentity: String, configuration: String,
         tier: CacheTier? = nil, previewLongEdge: Int? = nil,
         engineVersion: String, version: Int = CacheKey.formatVersion) {
        self.version = version
        self.kind = kind
        self.sourceIdentity = sourceIdentity
        self.configuration = configuration
        self.tier = tier
        self.previewLongEdge = previewLongEdge
        self.engineVersion = engineVersion
    }

    /// File identity without the path, so a rename is a hit and modification
    /// elsewhere is a miss.
    static func sourceIdentity(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [
            .volumeIdentifierKey, .fileResourceIdentifierKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return url.standardizedFileURL.path
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return [
            String(describing: values.volumeIdentifier),
            String(describing: values.fileResourceIdentifier),
            String(values.fileSize ?? 0),
            String(modified),
        ].joined(separator: "|")
    }
}

/// The mutable half of one cache value. Both the RAM entry and the SQLite row
/// rank through `priority(clock:)`.
struct CacheValue: Equatable, Sendable {
    var hits: Int
    let costMs: Double
    let bytes: Int
    var lastUsed: Double

    init(hits: Int = 0, costMs: Double, bytes: Int, lastUsed: Double) {
        self.hits = hits
        self.costMs = costMs
        self.bytes = bytes
        self.lastUsed = lastUsed
    }

    func priority(clock: Double) -> Double {
        gdsfPriority(hits: hits, costMs: costMs, bytes: bytes, clock: clock)
    }

    mutating func hit(at clock: Double) {
        hits += 1
        lastUsed = clock
    }
}

/// GDSF-shaped value density from IMPL §6.3. `clock` is the priority of the
/// last evicted entry, and prevents an old high-value entry from becoming
/// immortal.
func gdsfPriority(hits: Int, costMs: Double, bytes: Int, clock: Double) -> Double {
    clock + Double(max(1, hits)) * max(0, costMs) / (Double(max(1, bytes)) / 1_000_000)
}
