// Import decisions use the visible order, never the editor's picked set.
import Foundation

enum ImportSelection {
    static let preferenceKey = "ui2.showFolderImport"

    static func range(in urls: [URL], anchor: URL?, end: URL) -> Set<URL> {
        guard let b = urls.firstIndex(of: end) else { return [] }
        let a = anchor.flatMap { urls.firstIndex(of: $0) } ?? b
        return Set(urls[min(a, b)...max(a, b)])
    }

    /// Only suppress paired JPEGs. A JPEG-only shoot must still be importable.
    static func removingPairedJPEGs(_ urls: [URL], rawExtensions: Set<String>) -> [URL] {
        func key(_ url: URL) -> String { url.deletingPathExtension().standardizedFileURL.path.lowercased() }
        let raw = Set(urls.filter { rawExtensions.contains($0.pathExtension.lowercased()) }.map(key))
        return urls.filter {
            !(["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && raw.contains(key($0)))
        }
    }

    static func filtered(_ urls: [URL], minimumRating: Int = 0,
                         checkedOnly: Bool = false, checked: Set<URL>, ratings: [URL: Int],
                         hiding duplicates: Set<URL> = []) -> [URL] {
        urls.filter { (ratings[$0] ?? 0) >= minimumRating && (!checkedOnly || checked.contains($0))
                      && !duplicates.contains($0) }
    }

    /// What recognises a suspected duplicate: size plus a digest of the
    /// first 64 KB, the same sample `Sidecar.Source` records. A warning only —
    /// never a reason to share a rating or a grade (see `Ratings`).
    struct Fingerprint: Hashable, Sendable {
        let size: Int
        let headDigest: String

        static func of(_ url: URL) -> Fingerprint? {
            let source = Sidecar.identity(of: url)
            guard let size = source.size, let digest = source.headDigest else { return nil }
            return Fingerprint(size: size, headDigest: digest)
        }
    }

    /// Each file that looks like a copy of another, mapped to the path of the
    /// one it copies. Two cases, as Lightroom's "suspected duplicates":
    ///
    ///  - a second file in this listing with the same fingerprint (the first
    ///    in `urls` order is the original);
    ///  - a file whose fingerprint the catalog or the sidecar store already
    ///    knows at another path — the same card copied into two folders, or a
    ///    folder already rated or developed somewhere else.
    ///
    /// `knownElsewhere` returns existing paths for a fingerprint; a file's own
    /// path in it is ignored, so reopening a folder flags nothing.
    static func suspectedDuplicates(_ urls: [URL], fingerprints: [URL: Fingerprint],
                                    knownElsewhere: (Fingerprint) -> [String]) -> [URL: String] {
        let listed = Set(urls.map { $0.standardizedFileURL.path })
        var first: [Fingerprint: URL] = [:]
        var out: [URL: String] = [:]
        for url in urls {
            guard let fingerprint = fingerprints[url] else { continue }
            if let original = first[fingerprint] {
                out[url] = original.standardizedFileURL.path
                continue
            }
            first[fingerprint] = url
            let own = url.standardizedFileURL.path
            if let other = knownElsewhere(fingerprint).first(where: { $0 != own && !listed.contains($0) }) {
                out[url] = other
            }
        }
        return out
    }

    static func importURLs(_ checked: Set<URL>) -> [URL] {
        checked.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
